# Brief de implementação — KybExpansion

## Contexto para o Claude Code

Estou trabalhando num fork local de desenvolvimento do `lago-api` (clonado via
`git clone --recurse-submodules` do repositório `getlago/lago`, rodando com
`docker-compose.dev.yml`). Quero construir uma **extensão isolada**, sem editar
nenhum arquivo original do Lago, seguindo o princípio de "fork e estende, nunca
altera o core" — o objetivo declarado é minimizar o diff de merge contra o
upstream e deixar 100% claro o que é meu código vs. código do Lago.

Todo o código novo deve viver sob o namespace Ruby `KybExpansion`, em
arquivos novos. Nenhuma linha de arquivo já existente do Lago deve ser editada,
**exceto**, se estritamente necessário, uma única linha de `require`/`prepend`
dentro de um initializer novo (`config/initializers/kyb_expansion.rb`) —
isso conta como "arquivo novo", não como edição do core.

## O problema de negócio que a extensão resolve

Em produtos de verificação de identidade B2B (KYC/KYB), uma decisão de **KYB**
(Know Your Business) não é atômica: internamente, ela envolve validar a pessoa
jurídica e rastrear a estrutura societária até identificar os **UBOs**
(*Ultimate Beneficial Owners* — beneficiários finais), aplicando efetivamente
uma verificação de **KYC** para cada um deles.

Hoje, se o produto manda para o billing apenas um evento `kyb_decision`, o
sistema de billing perde a granularidade real do custo/volume de KYC associado.
A extensão deve **expandir automaticamente** um evento `kyb_decision` recebido
em N eventos derivados `kyc_decision` (um por UBO), preservando rastreabilidade
completa entre o evento pai e os eventos filhos.

## Estratégia técnica escolhida: prepend in-process (não usar service externo)

Decisão já tomada, não reabrir essa discussão: a expansão deve ser feita via
`Module#prepend` na classe Ruby responsável por processar a criação de eventos
via `POST /api/v1/events` — **não** via chamada HTTP externa à própria API.
Queremos observar o resultado do fluxo original de criação de evento, e reagir
a ele enfileirando um job assíncrono, sem nunca decidir o retorno do método
original.

## Passo 1 — Investigação (fazer antes de escrever qualquer código)

1. Localizar a classe/service que processa a criação de eventos via API.
   Ponto de partida sugerido: `grep -rn "class.*CreateService" api/app/services/events/`
   e `grep -rn "def create" api/app/controllers/api/v1/events_controller.rb`.
2. Confirmar a assinatura pública do método principal desse service (nome do
   método de entrada — provavelmente `call` — e o que ele retorna: um objeto
   `Result` com algo como `.success?` e `.event`, ou outro padrão).
3. Confirmar como um evento de uso é modelado (nome exato do model, e onde
   ficam propriedades customizadas — provavelmente uma coluna `properties`
   tipo JSON no model `Event`).
4. Confirmar a convenção de pastas usada no projeto para jobs assíncronos
   (`app/jobs/` vs `app/workers/` vs algo específico do Lago) e para
   inicializadores.
5. Reportar essas descobertas antes de prosseguir para a implementação, para
   validação.

## Passo 2 — Estrutura de arquivos a criar

```
config/initializers/kyb_expansion.rb
app/services/kyb_expansion/expand_kyb_decision.rb      # módulo do prepend
app/jobs/kyb_expansion/kyb_expansion_job.rb             # job assíncrono
spec/kyb_expansion/expand_kyb_decision_spec.rb
spec/kyb_expansion/kyb_expansion_job_spec.rb
```

## Passo 3 — Comportamento esperado

### `KybExpansion::ExpandKybDecision` (módulo de prepend)

- Dá `prepend` na classe de criação de eventos identificada no Passo 1.
- Sobrescreve o método principal chamando `super` **primeiro, sempre**.
- Após obter o resultado de `super`, verifica: se `result.success?` e o
  `code` do evento criado é `"kyb_decision"`, enfileira
  `KybExpansion::KybExpansionJob.perform_async(result.event.id)`.
- Retorna exatamente o `result` original, sem modificação — a extensão nunca
  altera o comportamento observável do fluxo original para quem chamou a API.
- Deve respeitar uma feature flag via variável de ambiente
  `KYB_EXPANSION_ENABLED` (default `false`): se desligada,
  o `prepend` deve ser um no-op completo (chama `super` e não faz mais nada).

### `KybExpansion::KybExpansionJob` (job assíncrono)

- Recebe o `id` do evento de KYB já persistido.
- Lê de `event.properties` uma lista de UBOs (assumir o formato
  `{"ubo_ids": ["uuid1", "uuid2", ...]}` — deixar isso documentado como uma
  premissa assumida, já que não temos o produtor real desse evento).
- Se a lista estiver vazia ou ausente, **não falhar**: logar um aviso
  (`Rails.logger.warn`) indicando que o evento de KYB chegou sem metadado de
  UBO e a expansão foi pulada, e encerrar sem erro.
- Para cada UBO, criar um evento derivado chamando a **mesma classe original
  de criação de evento do Lago** (não reimplementar a lógica de criação),
  passando:
  - `code: "kyc_decision"`
  - `transaction_id` **determinístico**: `"#{evento_pai.transaction_id}_ubo_#{index}"`
    (garante idempotência — reprocessar o mesmo job nunca duplica eventos)
  - `external_subscription_id`: igual ao do evento pai
  - `properties`: incluir `derived_from: evento_pai.transaction_id` e `ubo_id`
- O job deve ser idempotente: rodá-lo duas vezes para o mesmo evento pai não
  pode gerar eventos duplicados (a unicidade de `transaction_id` já cuida disso
  se o Lago tiver constraint de unicidade nesse campo — confirmar que existe).
- Deve rodar na fila `events` do Sidekiq (reaproveitar a fila já existente do
  Lago para esse tipo de carga, não criar uma fila nova sem necessidade).

## Passo 4 — Testes obrigatórios

1. Com a feature flag desligada: criar um evento `kyb_decision` e confirmar
   que **nenhum** job é enfileirado e o comportamento é idêntico ao Lago
   original (teste de regressão/não-interferência).
2. Com a flag ligada: criar um evento `kyb_decision` com 3 UBOs nas
   `properties` e confirmar que exatamente 3 eventos `kyc_decision` derivados
   são criados, com `transaction_id` no formato esperado.
3. Rodar o job duas vezes para o mesmo evento pai e confirmar que não há
   duplicação (idempotência).
4. Criar um evento `kyb_decision` sem `ubo_ids` e confirmar que o job não
   levanta exceção e loga o aviso esperado.
5. Confirmar que um evento com `code` diferente de `kyb_decision` nunca
   dispara o job (o prepend não deve reagir a outros tipos de evento).

## Fora de escopo (não fazer)

- Não implementar nenhuma UI/dashboard para isso.
- Não modificar o cálculo de fees/charges do Lago.
- Não tentar integrar com nenhum produto real de KYB (isso é uma simulação
  conceitual, o contrato de dados de entrada é assumido, não real).
- Não editar nenhum arquivo dentro de `app/services/events/`,
  `app/models/event.rb`, ou qualquer arquivo original do Lago, além da
  exceção já descrita no initializer.

## Entregável esperado

- Código funcional seguindo a estrutura acima.
- Testes passando.
- Um resumo curto (5-10 linhas) do que foi encontrado na investigação do
  Passo 1 (nome real das classes, formato real do `Result`), para eu
  incorporar na documentação da extensão.
