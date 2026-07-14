# KybExpansion

> Extensão de estudo sobre o Lago (usage-based billing open source), demonstrando como
> estender o sistema sem modificar nenhum arquivo original — princípio "fork e estende,
> nunca altera o core".

---

## Status

Projeto pessoal de estudo técnico.

---

## O problema de negócio modelado

Em produtos de verificação de identidade B2B (KYC/KYB), uma decisão de **KYB**
(*Know Your Business*) não é atômica internamente: ela exige rastrear a estrutura
societária até identificar os **UBOs** (*Ultimate Beneficial Owners* — beneficiários
finais), aplicando uma verificação de **KYC** para cada um deles.

Um sistema de billing que recebe apenas "1 decisão de KYB" como unidade de cobrança
perde a granularidade real de custo e volume de KYC associado.

**A extensão resolve isso:** ao receber um evento `kyb_decision` no Lago, expande
automaticamente em N eventos derivados `kyc_decision` — um por UBO — com rastreabilidade
completa entre evento pai e eventos filhos.

> ⚠️ **Premissa simulada:** o contrato de entrada (`properties.ubo_ids`) é assumido
> como `{"ubo_ids": ["uuid1", "uuid2", ...]}`. Não há integração real com nenhum
> produto de KYB — este é um exercício técnico conceitual.

---

## Princípio arquitetural: estender sem alterar o núcleo

O Lago é mantido ativamente upstream (`getlago/lago-api`). Editar arquivos originais
cria dívida de merge que cresce a cada `git pull`. A estratégia adotada:

- **Zero edições** em qualquer arquivo existente do Lago
- **Um único ponto de conexão**: `Module#prepend` aplicado via initializer
- **Namespace próprio**: todo o código novo vive sob `KybExpansion`

Isso permite sincronizar com o upstream com `git merge main` sem conflitos estruturais.

---

## Duas implementações incluídas

Este repositório contém **duas implementações independentes** da mesma extensão, para fins comparativos:

| | Abordagem 1: `Module#prepend` | Abordagem 2: Kafka Consumer |
|---|---|---|
| **Trigger** | In-process, dentro do request HTTP | Assíncrono, via mensagem Kafka |
| **Cobre single event** | ✅ | ✅ |
| **Cobre batch event** | ❌ | ✅ |
| **Cobre ClickHouse store** | ✅ | ✅ |
| **Dependência de infra** | Nenhuma | Kafka/Redpanda rodando |
| **Arquivo de borda** | `config/initializers/kyb_expansion.rb` | `karafka.rb` (8 linhas) |
| **Job** | `KybExpansionJob` (recebe `event.id`) | `KybExpansionFromPayloadJob` (recebe payload Kafka) |

Ambas são ativadas pela mesma flag `KYB_EXPANSION_ENABLED=true`. Se ambas estiverem ativas simultaneamente, a idempotência garantida pelo índice único do banco impede duplicação — a segunda execução é silenciosamente descartada.

---

## Como funciona tecnicamente

### Abordagem 1: Ponto de extensão via prepend

O initializer `config/initializers/kyb_expansion.rb` usa
`Rails.application.config.to_prepare` (e não o corpo do initializer diretamente)
para aplicar o prepend. Isso é necessário porque em modo de desenvolvimento o Rails
recarrega classes a cada request — aplicar o prepend fora do `to_prepare` faria o
módulo desaparecer após o primeiro reload.

```ruby
Rails.application.config.to_prepare do
  Events::CreateService.prepend(KybExpansion::ExpandKybDecision)
end
```

### O módulo de prepend (`app/services/kyb_expansion/expand_kyb_decision.rb`)

`KybExpansion::ExpandKybDecision` sobrescreve o método `call` de
`Events::CreateService` (a classe real do Lago responsável por persistir eventos via
`POST /api/v1/events`):

1. Chama `super` **primeiro, sempre** — a lógica original do Lago nunca é contornada
2. Observa o resultado: se `result.success?` e `result.event.code == "kyb_decision"`
   e a feature flag `KYB_EXPANSION_ENABLED=true` está ativa, enfileira o job
3. Retorna exatamente o `result` original — o comportamento observável da API não muda

A guarda em `code == "kyb_decision"` previne loop infinito: os eventos derivados têm
code `"kyc_decision"` e não voltam a disparar o módulo.

### Abordagem 2: Kafka Consumer

`KybExpansion::KybDecisionEventConsumer` consome o tópico `LAGO_KAFKA_RAW_EVENTS_TOPIC` — o mesmo tópico para o qual o `Events::KafkaProducerService` publica **todos** os eventos recebidos, independentemente de serem single ou batch e de qual store (PostgreSQL ou ClickHouse) está sendo usado. O consumer usa seu próprio consumer group (`kyb_expansion_kyb_decision_consumer`), garantindo offset independente e sem interferência com outros consumers do Lago.

Fluxo:
1. `POST /api/v1/events` (single) **ou** `POST /api/v1/events/batch` → `KafkaProducerService` publica no tópico
2. `KybDecisionEventConsumer#consume` filtra por `code == "kyb_decision"` e `KYB_EXPANSION_ENABLED`
3. Enfileira `KybExpansionFromPayloadJob` com o payload JSON da mensagem
4. O job usa os campos do payload diretamente — sem precisar carregar o `Event` do banco, funciona com ClickHouse store também

O registro do consumer em `karafka.rb` é a única edição num arquivo original do Lago (8 linhas, gated em `LAGO_KAFKA_RAW_EVENTS_TOPIC`).

---

### O job assíncrono (`app/jobs/kyb_expansion/kyb_expansion_job.rb`)

`KybExpansion::KybExpansionJob` roda na fila `:events` (mesma fila já usada pelo
`Events::PostProcessJob` do Lago — sem criar filas novas desnecessariamente):

1. Lê `event.properties["ubo_ids"]`
2. Se ausente/vazio: loga `Rails.logger.warn` e encerra sem erro
3. Para cada UBO, chama `Events::CreateService.call` com:
   - `code: "kyc_decision"`
   - `transaction_id: "#{parent.transaction_id}_ubo_#{index}"` (determinístico)
   - `external_subscription_id`: igual ao do evento pai
   - `properties: { derived_from: parent.transaction_id, ubo_id: ubo_id }`

### Idempotência

O banco já impõe `UNIQUE INDEX index_unique_transaction_id ON events(organization_id, external_subscription_id, transaction_id)`. O `Events::CreateService` captura a violação como `value_already_exist` (não como exceção). Como o job usa `.call` (não `.call!`), reprocessar o mesmo evento pai duas vezes produz no máximo N no-ops silenciosos na segunda execução — sem duplicatas, sem erros.

---

## Estrutura de arquivos da extensão

```
# Abordagem 1 — prepend
config/initializers/kyb_expansion.rb                        # ponto de conexão via to_prepare
app/services/kyb_expansion/expand_kyb_decision.rb           # módulo de prepend
app/jobs/kyb_expansion/kyb_expansion_job.rb                 # job (recebe event.id do DB)
spec/kyb_expansion/expand_kyb_decision_spec.rb
spec/kyb_expansion/kyb_expansion_job_spec.rb

# Abordagem 2 — Kafka consumer
karafka.rb                                                  # +8 linhas de rota (único arquivo core editado)
app/consumers/kyb_expansion/kyb_decision_event_consumer.rb  # consumer
app/jobs/kyb_expansion/kyb_expansion_from_payload_job.rb    # job (recebe payload Kafka)
spec/kyb_expansion/kyb_decision_event_consumer_spec.rb
spec/kyb_expansion/kyb_expansion_from_payload_job_spec.rb

# Documentação
kyb-expansion/README.md
kyb-expansion/demo_catalog_setup.sh
```

---

## Como rodar localmente

### Pré-requisitos

- Lago rodando via `docker-compose.dev.yml`
- Catálogo de demo configurado:

```bash
bash kyb-expansion/demo_catalog_setup.sh
```

Cria: billable metrics (`kyb_decision`, `kyc_decision`, etc.), plano `identity_platform_demo`,
cliente `demo_customer_001` com subscription `demo_customer_001_sub`.

### Ativar a extensão

```bash
echo "KYB_EXPANSION_ENABLED=true" >> api/.env.development
lago restart api
lago restart api-worker
```

### Rodar os testes

```bash
lago exec api bundle exec rspec spec/kyb_expansion/
```

### Validação manual (roteiro completo)

```bash
# 1. Acompanhar logs do worker em outra aba
lago logs -f api-worker

# 2. Disparar evento kyb_decision com 3 UBOs
curl -s --location --request POST "$LAGO_URL/api/v1/events" \
  --header "Authorization: Bearer $LAGO_API_KEY" \
  --header 'Content-Type: application/json' \
  --data-raw '{
    "event": {
      "transaction_id": "manual_test_kyb_'"$(date +%s)"'",
      "external_subscription_id": "demo_customer_001_sub",
      "code": "kyb_decision",
      "properties": { "ubo_ids": ["ubo_1", "ubo_2", "ubo_3"] }
    }
  }'

# 3. Confirmar no banco que os eventos derivados existem
lago exec api bundle exec rails console
# Event.where("transaction_id LIKE ?", "manual_test_kyb_%").pluck(:transaction_id, :code)
# Esperado: 1 kyb_decision + 3 kyc_decision (_ubo_0, _ubo_1, _ubo_2)

# 4. Confirmar nas métricas de uso
curl -s "$LAGO_URL/api/v1/customers/demo_customer_001/current_usage?external_subscription_id=demo_customer_001_sub" \
  --header "Authorization: Bearer $LAGO_API_KEY" | \
  jq '.customer_usage.charges_usage[] | {units, name: .billable_metric.name}'
# kyc_decision deve mostrar 3 unidades

# 5. Testar idempotência: reenviar o MESMO transaction_id do evento pai
#    Confirmar que nenhum kyc_decision duplicado aparece no banco

# 6. Testar com a flag desligada
#    Remover KYB_EXPANSION_ENABLED do .env.development, reiniciar api e api-worker
#    Disparar novo kyb_decision e confirmar que nenhum kyc_decision é gerado
```

---

## Resultado dos testes automatizados

```
KybExpansion::ExpandKybDecision
  when KYB_EXPANSION_ENABLED is not set
    does not enqueue KybExpansionJob
    returns a successful result
  when KYB_EXPANSION_ENABLED is true
    when event code is kyb_decision
      enqueues KybExpansionJob with the created event id
      returns the original result unchanged
    when event code is not kyb_decision
      does not enqueue KybExpansionJob
    when CreateService returns a failure (duplicate transaction_id)
      does not enqueue KybExpansionJob
      returns the failure result as-is

KybExpansion::KybExpansionJob
  #perform
    when the parent event has 3 UBOs
      creates exactly 3 kyc_decision events
      creates events with deterministic transaction_ids
      sets derived_from and ubo_id in each child event properties
      sets external_subscription_id equal to the parent event
    when ubo_ids is absent from properties
      does not create any events
      logs a warning
      does not raise
    when ubo_ids is an empty array
      does not create any events
      logs a warning
    when the job runs twice for the same parent event (idempotency)
      does not duplicate kyc_decision events
      does not raise on the second run

18 examples, 0 failures
```

## Resultado da validação manual

### Eventos no banco após disparo com 3 UBOs

```ruby
Event.where("transaction_id LIKE ?", "manual_test_kyb_%").pluck(:transaction_id, :code)
# [["manual_test_kyb_1784049805", "kyb_decision"],
#  ["manual_test_kyb_1784049805_ubo_0", "kyc_decision"],
#  ["manual_test_kyb_1784049805_ubo_1", "kyc_decision"],
#  ["manual_test_kyb_1784049805_ubo_2", "kyc_decision"]]
```

### Métricas de uso após expansão

```json
{ "units": "3.0", "name": "kyc_decision" }
{ "units": "2.0", "name": "kyb_decision" }
```

`kyc_decision` registrou 3 unidades — o billing engine contabilizou cada evento derivado individualmente.

### Idempotência confirmada

Reenviar o mesmo `transaction_id` do evento pai não gerou duplicatas — o índice único do banco (`UNIQUE INDEX index_unique_transaction_id`) bloqueou silenciosamente as inserções duplicadas via `value_already_exist`.

### Flag desligada

Com `KYB_EXPANSION_ENABLED` ausente: nenhum evento `kyc_decision` derivado foi gerado, comportamento idêntico ao Lago original.

---

## Vídeo explicativo

> 🎥 Vídeo: [link a adicionar]
