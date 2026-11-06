# azure-study-api

Projeto de estudo para aprender Azure na prática: uma API pequena de anotações (FastAPI) com tudo que uma equipe de plataforma monta ao redor dela, **sem nenhuma senha ou chave de longa duração**.

Cada etapa é escrita e explicada passo a passo, então o repositório cresce aos poucos. O quadro de progresso abaixo mostra em que ponto está.

## Arquitetura alvo

```
GitHub Actions ──OIDC──▶ Resource group rg-azstudy-dev
 (Terraform + build)       ACR ──▶ Container App (FastAPI, min 0) ──▶ Key Vault (segredo)
        │                                  │
        ▼                                  ├──▶ Cosmos DB (free tier, RBAC)
 Storage Account                           └──▶ Log Analytics (teto diário)
 (state do Terraform)
```

| Peça | Escolha | Equivalente na AWS |
| --- | --- | --- |
| Execução | Azure Container Apps (escala a zero) | ECS Fargate / App Runner |
| Imagens | Azure Container Registry (ACR) | ECR |
| Banco | Cosmos DB NoSQL, free tier, acesso por RBAC | DynamoDB |
| Segredo | Key Vault | Secrets Manager / KMS |
| Identidade do app | Managed identity | IAM role da task |
| Identidade do pipeline | App registration + credencial federada (OIDC) | IAM role com OIDC provider |
| Logs | Log Analytics (KQL) | CloudWatch Logs Insights |
| State do Terraform | Blob Storage | S3 (o lock é nativo, sem DynamoDB) |
| IaC | Terraform (azurerm 4.x) | Terraform (aws) |
| CI/CD | GitHub Actions com OIDC | GitHub Actions com OIDC |

## Decisões e trade-offs

- **Container Apps em vez de AKS:** cabe na cota gratuita e dispensa gerenciar nós.
- **RBAC no banco, não chave:** só a managed identity do app acessa o Cosmos DB.
- **OIDC em vez de client secret:** o pipeline prova quem é por token e recebe acesso temporário.
- **Escala a zero e teto de logs:** os dois itens que mais evitam surpresa na fatura.

## Progresso

- [x] Orçamento e conta Azure (budget de US$ 10 com alertas)
- [ ] Bootstrap: resource groups, state em Blob e identidade do pipeline (OIDC)
- [ ] Terraform: base (logs, ACR, identidade)
- [ ] Terraform: Key Vault e Cosmos DB
- [ ] Terraform: Container App
- [ ] API FastAPI e Dockerfile
- [ ] Pipeline no GitHub Actions
- [ ] Observabilidade (consultas KQL) e governança (Policy, lock, RBAC mínimo)
- [ ] Teardown

## Como ficar no plano gratuito

Região única (`eastus2`), `min_replicas = 0` com 0,25 vCPU, Cosmos DB free tier (400 RU/s de 1.000 gratuitos), `daily_quota_gb = 0.1` no Log Analytics e destruição de tudo ao fim de cada sessão.

## Licença

[MIT](LICENSE)
