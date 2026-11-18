# Observabilidade com Log Analytics (KQL)

O ambiente do Container Apps já envia os logs ao workspace `log-azstudy-dev`. No portal:
**workspace → Logs**. As tabelas do Container Apps terminam em `_CL`.

> Na AWS, o equivalente é o **CloudWatch Logs Insights**; KQL faz o papel da query language dele.

## 1. Logs da API na última hora

```kusto
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == 'ca-study-api'
| where TimeGenerated > ago(1h)
| project TimeGenerated, RevisionName_s, Log_s
| order by TimeGenerated desc
```

## 2. Erros por janela de 5 minutos

```kusto
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == 'ca-study-api'
| where Log_s has_any ('error', 'exception')
| summarize erros = count() by bin(TimeGenerated, 5m)
```

## 3. Ciclo de vida: revisões, subida e descida de réplicas

```kusto
ContainerAppSystemLogs_CL
| where ContainerAppName_s == 'ca-study-api'
| project TimeGenerated, Reason_s, Type_s, Log_s
| order by TimeGenerated desc
| take 50
```

**Exercício:** faça umas 30 chamadas à API com um `for` de `curl`, espere alguns minutos
sem tráfego e rode esta consulta. Você deve ver o app **escalar a zero** e voltar na
chamada seguinte (a primeira chamada depois de parado demora alguns segundos).

## 4. Quanto já foi ingerido (compare com os 5 GB gratuitos por mês)

```kusto
Usage
| where TimeGenerated > ago(7d) and IsBillable == true
| summarize GB = sum(Quantity) / 1024 by bin(TimeGenerated, 1d)
```

O workspace tem `daily_quota_gb = 0.1`: ao atingir o teto, a coleta para pelo resto do dia.

## 5. Auditoria do Key Vault

Logs de **recurso** (Key Vault, Cosmos DB...) não vão sozinhos para o Log Analytics: é
preciso um *diagnostic setting*, que está em `infra/main.tf`
(`azurerm_monitor_diagnostic_setting.kv`). Depois de ler ou gravar um segredo:

```kusto
AzureDiagnostics
| where ResourceProvider == 'MICROSOFT.KEYVAULT'
| project TimeGenerated, OperationName, CallerIPAddress, ResultSignature
| order by TimeGenerated desc
```

A diferença entre os dois tipos de log é um bom ponto de entrevista: **logs de plataforma
do Container Apps** chegam pelo environment; **logs de recurso** exigem diagnostic setting
(na AWS, pense em CloudTrail e logs de serviço, que também precisam ser habilitados e roteados).
