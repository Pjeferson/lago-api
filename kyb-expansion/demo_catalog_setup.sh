#!/usr/bin/env bash
#
# demo_catalog_setup.sh
#
# Popula uma instância local do Lago (ambiente de dev, docker-compose.dev.yml)
# com o catálogo de produtos necessário para demonstrar a extensão KybExpansion:
#
#   - billable metrics para cada produto simulado, INCLUINDO "kyc_decision"
#     isolada (métrica que faltava na primeira versão deste script — sem ela,
#     os eventos derivados que a extensão KybExpansion gera não têm nenhum
#     charge configurado para cobrar, e a demonstração fica "muda").
#   - um plano com um charge por métrica.
#   - um cliente e uma subscription de demonstração.
#
# Pré-requisito: ambiente de dev do Lago já no ar (lago up -d) e uma API key
# válida (LAGO_ORG_API_KEY, se você usou LAGO_CREATE_ORG=true, ou peguem
# manualmente no dashboard em http://app.lago.dev ou http://localhost).
#
# Uso:
#   export LAGO_API_KEY="sua_api_key_aqui"
#   ./demo_catalog_setup.sh
#
set -uo pipefail
# (removi o -e do set: com debug ativo queremos ver TODAS as chamadas e seus
#  erros até o fim, em vez de o script morrer na primeira falha sem contexto)

LAGO_URL="${LAGO_URL:-https://api.lago.dev}"
API_KEY="${LAGO_API_KEY:-paulos_experiment_key_dev}"
CURRENCY="${CURRENCY:-USD}"   # troque para BRL se sua instância aceitar
DEBUG="${DEBUG:-true}"        # export DEBUG=false pra silenciar o corpo/status de cada chamada

hr() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# request(): função única usada por post()/get(), que SEMPRE captura o status
# HTTP separado do corpo da resposta (via --write-out com um delimitador),
# imprime os dois quando DEBUG=true, e nunca deixa uma falha passar batido
# pro jq tentar parsear silenciosamente.
# ---------------------------------------------------------------------------
request() {
  local method="$1" path="$2" data="${3:-}"
  local response http_code body

  if [ -n "$data" ]; then
    response=$(curl -s --location --request "$method" "$LAGO_URL$path" \
      --header "Authorization: Bearer $API_KEY" \
      --header 'Content-Type: application/json' \
      --data-raw "$data" \
      --write-out $'\n---HTTP_STATUS---%{http_code}')
  else
    response=$(curl -s --location --request "$method" "$LAGO_URL$path" \
      --header "Authorization: Bearer $API_KEY" \
      --write-out $'\n---HTTP_STATUS---%{http_code}')
  fi

  # Extração portável (sem depender de grep -P, ausente no grep padrão do macOS):
  # a última linha da resposta é sempre "---HTTP_STATUS---NNN" por causa do
  # --write-out acima; tudo antes disso é o corpo original da resposta.
  local status_line
  status_line=$(echo "$response" | tail -n1)
  http_code="${status_line##*---HTTP_STATUS---}"
  body=$(echo "$response" | sed '$d')

  if [ "$DEBUG" = "true" ]; then
    echo "  -> $method $path" >&2
    echo "  -> HTTP status: ${http_code:-SEM RESPOSTA — provável erro de conexão/DNS/TLS}" >&2
    echo "  -> corpo bruto: $body" >&2
  fi

  if [ -z "$http_code" ]; then
    echo "  !! ERRO DE CONEXÃO em $method $path — curl não completou a requisição." >&2
    echo "     Verifique se LAGO_URL='$LAGO_URL' é o host correto do seu ambiente" >&2
    echo "     (no ambiente de dev via Traefik costuma ser https://api.lago.dev, não localhost:3000)." >&2
    echo "$body"
    return 1
  fi

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "  !! ERRO HTTP $http_code em $method $path — veja o corpo acima para a mensagem exata da API." >&2
    echo "$body"
    return 1
  fi

  echo "$body"
  return 0
}

post() { request POST "$1" "$2"; }
get()  { request GET "$1"; }

# ---------------------------------------------------------------------------
# exists(): checagem silenciosa (não passa pelo DEBUG de request()) de que um
# recurso já existe via GET no seu endpoint "show" (por code/external_id).
# Retorna 0 (existe) se HTTP 200, 1 caso contrário — usada por todos os passos
# de criação abaixo para o script ser seguro de rodar mais de uma vez.
# ---------------------------------------------------------------------------
exists() {
  local path="$1"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --location --request GET "$LAGO_URL$path" \
    --header "Authorization: Bearer $API_KEY")
  [ "$http_code" = "200" ]
}

# ---------------------------------------------------------------------------
# PREFLIGHT CHECK — roda antes de tudo, pra falhar rápido e com uma mensagem
# clara se o host/API key estiverem errados, em vez de descobrir isso só
# depois de tentar criar a primeira billable metric.
# ---------------------------------------------------------------------------
hr "Preflight: testando conectividade e autenticação"
preflight=$(get "/api/v1/billable_metrics?per_page=1")
preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  echo ""
  echo "Preflight falhou. Antes de continuar, confirme manualmente:"
  echo "  1) curl -v $LAGO_URL/                     (o host responde?)"
  echo "  2) curl -vk https://api.lago.dev/          (se estiver no ambiente de dev com Traefik)"
  echo "  3) A API key usada é a mesma exibida no dashboard (Settings > Developers > API keys)?"
  echo "  4) A organização já foi criada (sign up feito pelo menos uma vez na UI)?"
  exit 1
fi
echo "Preflight OK — API respondendo e autenticação aceita."

# ---------------------------------------------------------------------------
# 1. BILLABLE METRICS
#    Uma por produto/capacidade cobrável. "kyc_decision" existe agora como
#    métrica própria e independente — tanto para ser vendida diretamente
#    (um cliente que só faz KYC) quanto para receber os eventos derivados
#    que a extensão KybExpansion vai gerar a partir de um "kyb_decision".
# ---------------------------------------------------------------------------
hr "Criando Billable Metrics"

create_metric() {
  local name="$1" code="$2" desc="$3" recurring="$4"
  local agg_type="${5:-count_agg}"
  local field_name="${6:-}"

  if exists "/api/v1/billable_metrics/$code"; then
    echo "  (já existe, pulando) billable_metric code=$code"
    return 0
  fi

  local field_json=""
  if [ -n "$field_name" ]; then
    field_json="\"field_name\": \"$field_name\","
  fi

  post "/api/v1/billable_metrics" "{
    \"billable_metric\": {
      \"name\": \"$name\",
      \"code\": \"$code\",
      \"description\": \"$desc\",
      \"aggregation_type\": \"$agg_type\",
      $field_json
      \"recurring\": $recurring
    }
  }" | jq '.billable_metric.code, .billable_metric.lago_id'
}

create_metric "Face Match + Liveness" "face_match_liveness" \
  "Verificação biométrica facial com prova de vida" false

create_metric "OCR + Documentoscopia" "ocr_documentoscopy" \
  "Extração de dados de documento e detecção de fraude documental" false

create_metric "Deepfake Detection" "deepfake_detection" \
  "Detecção de manipulação digital / cross-biometric match" false

create_metric "Device Intelligence Event" "device_intelligence_event" \
  "Evento de fingerprint/risco de dispositivo" false

create_metric "KYC Decision" "kyc_decision" \
  "Decisão individual de verificação de identidade de pessoa física" false

create_metric "KYB Decision" "kyb_decision" \
  "Decisão de verificação de pessoa jurídica (dispara expansão para UBOs)" false

create_metric "AML Monitored Entity" "aml_monitored_entity" \
  "Cliente final sob monitoramento contínuo de AML/PEP/sanções" true \
  "unique_count_agg" "monitored_entity_id"

hr "Recuperando IDs das métricas criadas"
BM_JSON=$(get "/api/v1/billable_metrics?per_page=50")
id_of() { echo "$BM_JSON" | jq -r --arg code "$1" '.billable_metrics[] | select(.code==$code) | .lago_id'; }

ID_FACE_MATCH=$(id_of face_match_liveness)
ID_OCR=$(id_of ocr_documentoscopy)
ID_DEEPFAKE=$(id_of deepfake_detection)
ID_DEVICE=$(id_of device_intelligence_event)
ID_KYC=$(id_of kyc_decision)
ID_KYB=$(id_of kyb_decision)
ID_AML=$(id_of aml_monitored_entity)

# ---------------------------------------------------------------------------
# 2. PLAN — um charge por métrica, incluindo agora um charge para
#    "kyc_decision" isolada. Preço da KYC deliberadamente menor que o do KYB
#    (reflete que é "o componente", não "a decisão composta completa").
# ---------------------------------------------------------------------------
hr "Criando o Plan de demonstração"

if exists "/api/v1/plans/identity_platform_demo"; then
  echo "  (já existe, pulando) plan code=identity_platform_demo"
  echo "  Se você mudou preços/charges no script, apague o plano manualmente"
  echo "  antes de rodar de novo (a criação não atualiza planos existentes)."
else
  post "/api/v1/plans" "{
  \"plan\": {
    \"name\": \"Identity Platform — Demo Plan\",
    \"code\": \"identity_platform_demo\",
    \"interval\": \"monthly\",
    \"amount_cents\": 0,
    \"amount_currency\": \"$CURRENCY\",
    \"pay_in_advance\": false,
    \"description\": \"Plano de demonstração multi-produto para o cenário de expansão KYB -> KYC\",
    \"charges\": [
      {
        \"billable_metric_id\": \"$ID_FACE_MATCH\",
        \"charge_model\": \"graduated\",
        \"invoice_display_name\": \"Face Match + Liveness\",
        \"properties\": {
          \"graduated_ranges\": [
            { \"from_value\": 0, \"to_value\": 5000, \"per_unit_amount\": \"0.90\", \"flat_amount\": \"0\" },
            { \"from_value\": 5001, \"to_value\": null, \"per_unit_amount\": \"0.65\", \"flat_amount\": \"0\" }
          ]
        }
      },
      {
        \"billable_metric_id\": \"$ID_OCR\",
        \"charge_model\": \"package\",
        \"invoice_display_name\": \"OCR + Documentoscopia\",
        \"properties\": { \"amount\": \"450\", \"free_units\": 0, \"package_size\": 1000 }
      },
      {
        \"billable_metric_id\": \"$ID_DEEPFAKE\",
        \"charge_model\": \"standard\",
        \"invoice_display_name\": \"Deepfake Detection\",
        \"properties\": { \"amount\": \"1.20\" }
      },
      {
        \"billable_metric_id\": \"$ID_DEVICE\",
        \"charge_model\": \"standard\",
        \"invoice_display_name\": \"Device Intelligence\",
        \"properties\": { \"amount\": \"0.15\" }
      },
      {
        \"billable_metric_id\": \"$ID_KYC\",
        \"charge_model\": \"standard\",
        \"invoice_display_name\": \"KYC Decision\",
        \"properties\": { \"amount\": \"0.35\" }
      },
      {
        \"billable_metric_id\": \"$ID_KYB\",
        \"charge_model\": \"package\",
        \"invoice_display_name\": \"KYB Decision\",
        \"properties\": { \"amount\": \"800\", \"free_units\": 0, \"package_size\": 100 }
      },
      {
        \"billable_metric_id\": \"$ID_AML\",
        \"charge_model\": \"standard\",
        \"invoice_display_name\": \"AML — Entidade monitorada/mês\",
        \"properties\": { \"amount\": \"3.50\" }
      }
    ]
  }
}" | jq '.plan.code, .plan.charges | length'
fi

# ---------------------------------------------------------------------------
# 3. CLIENTE + SUBSCRIPTION de demonstração
# ---------------------------------------------------------------------------
hr "Criando cliente de demonstração"

if exists "/api/v1/customers/demo_customer_001"; then
  echo "  (já existe, pulando) customer external_id=demo_customer_001"
else
  post "/api/v1/customers" "{
    \"customer\": {
      \"external_id\": \"demo_customer_001\",
      \"name\": \"Demo Identity Customer\",
      \"email\": \"billing@demo-customer.example\",
      \"currency\": \"$CURRENCY\"
    }
  }" | jq '.customer.external_id'
fi

hr "Assinando o plano"

if exists "/api/v1/subscriptions/demo_customer_001_sub"; then
  echo "  (já existe, pulando) subscription external_id=demo_customer_001_sub"
else
  post "/api/v1/subscriptions" '{
    "subscription": {
      "external_customer_id": "demo_customer_001",
      "external_id": "demo_customer_001_sub",
      "plan_code": "identity_platform_demo"
    }
  }' | jq '.subscription.status, .subscription.external_id'
fi

# ---------------------------------------------------------------------------
# 4. SANITY CHECK — dispara UM evento de kyb_decision manualmente aqui,
#    ANTES de qualquer extensão existir, só para confirmar que o catálogo
#    está correto e o evento "pai" sozinho já gera cobrança normalmente.
#    Isso isola qualquer problema de setup do problema de extensão depois.
# ---------------------------------------------------------------------------
hr "Enviando 1 evento de kyb_decision (sanity check, sem extensão ainda)"

SANITY_TX_ID="sanity_check_kyb_$(date +%s)"
post "/api/v1/events" "{
  \"event\": {
    \"transaction_id\": \"$SANITY_TX_ID\",
    \"external_subscription_id\": \"demo_customer_001_sub\",
    \"code\": \"kyb_decision\",
    \"properties\": { \"ubo_ids\": [\"ubo_1\", \"ubo_2\", \"ubo_3\"] }
  }
}" | jq '.'

hr "Consumo atual (deve mostrar 1 unidade de kyb_decision e 0 de kyc_decision)"
get "/api/v1/customers/demo_customer_001/current_usage?external_subscription_id=demo_customer_001_sub" | jq '.'

echo ""
echo "Setup concluído. Quando a extensão KybExpansion estiver ativa, repita o"
echo "envio de um evento kyb_decision com 'ubo_ids' e o current_usage deve"
echo "passar a mostrar também unidades de kyc_decision geradas automaticamente."