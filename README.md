# azure-study-api

Projeto de estudo para aprender Azure na prática: uma API pequena de anotações (FastAPI) com tudo que uma equipe de plataforma monta ao redor dela, **sem nenhuma senha ou chave de longa duração**.

O pipeline entra na Azure por **OIDC**; o Container App puxa a imagem do ACR, lê o segredo do Key Vault e grava no Cosmos DB, sempre por **managed identity**, e manda os logs ao Log Analytics.

## Arquitetura

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

- **Container Apps em vez de AKS:** cabe na cota gratuita e dispensa gerenciar nós; o AKS fica como evolução.
- **RBAC no banco, não chave:** `local_authentication_enabled = false`; só a managed identity do app acessa o Cosmos DB, com o papel de dados.
- **OIDC em vez de client secret:** o pipeline prova quem é por token e recebe acesso temporário. A credencial federada é restrita ao repositório e à branch `main` (o subject usa IDs imutáveis do GitHub).
- **Permissão mínima no pipeline:** `Contributor` e `RBAC Administrator` só no resource group da aplicação, nunca na subscription.
- **Escala a zero e teto de logs:** os dois itens que mais evitam surpresa na fatura.
- **State fora da aplicação:** o resource group do state sobrevive ao `destroy`, e o `destroy` é feito pelo Terraform, não por `az group delete`, para não perder as atribuições de papel do pipeline.

## Estrutura

```
app/        API FastAPI, Dockerfile e testes (pytest)
infra/      Terraform: logs, ACR, identidade, Key Vault, Cosmos DB, Container App
scripts/    bootstrap.sh (state + identidade OIDC) e teardown.sh
docs/       consultas KQL e governança (policy, lock, RBAC mínimo)
.github/    workflows: infra (validate, plan, apply, destroy) e app (test, deploy)
```

## Como reproduzir

Pré-requisitos: conta Azure free, Azure CLI, GitHub CLI e um fork deste repositório.

1. **Orçamento primeiro:** no Cost Management, crie um budget de US$ 10 com alertas em 50%, 80% e 100%.
2. **Bootstrap (uma vez):** `az login` e `bash scripts/bootstrap.sh`. Ajuste `GITHUB_REPO` para o seu `dono/repo`. Ele registra os resource providers, cria os resource groups, a storage do state e a identidade OIDC.
3. **Variáveis do GitHub:** em Settings → Secrets and variables → Actions → **Variables**, crie `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` e `TF_STATE_SA` com os valores impressos (são identificadores, não segredos).
4. **Infraestrutura:** Actions → **infra** → Run workflow → `apply`. Leva alguns minutos.
5. **Aplicação:** um push em `app/` (ou Actions → **app** → Run workflow) publica a imagem no ACR e atualiza o Container App.
6. **Teste:**

   ```bash
   URL="https://$(az containerapp show -n ca-study-api -g rg-azstudy-dev --query properties.configuration.ingress.fqdn -o tsv)"
   curl "$URL/health"
   curl -X POST "$URL/notes" -H 'Content-Type: application/json' -d '{"user_id":"aluno","text":"estudar RBAC"}'
   curl "$URL/notes?user_id=aluno"
   ```

7. **Ao terminar a sessão:** Actions → **infra** → Run workflow → `destroy`.

Para encerrar o projeto de vez (apaga também o state e a identidade do pipeline): `ARM_CLIENT_ID=<appId> bash scripts/teardown.sh`.

## Como ficar no plano gratuito

Região única (`eastus2`), `min_replicas = 0` com 0,25 vCPU, Cosmos DB free tier (400 RU/s de 1.000 gratuitos), `daily_quota_gb = 0.1` no Log Analytics e destruição de tudo ao fim de cada sessão. O ACR Standard é o item mais caro se a cota gratuita não se aplicar (cerca de US$ 0,67 por dia): destrua ao terminar.

## Progresso

- [x] Orçamento e conta Azure (budget de US$ 10 com alertas)
- [x] Bootstrap: resource groups, state em Blob e identidade do pipeline (OIDC)
- [x] Terraform: base (logs, ACR, identidade)
- [x] Terraform: Key Vault e Cosmos DB
- [x] Terraform: Container App
- [x] API FastAPI e Dockerfile (4 testes locais passando)
- [x] Pipeline no GitHub Actions (validate, plan, apply, destroy, test, deploy)
- [x] Observabilidade (consultas KQL) e governança (Policy, lock, RBAC mínimo): ver [docs/](docs/)
- [x] Teardown

**Status de validação:** o login OIDC, o `terraform init` e o `plan` foram validados no CI; o `apply` da base (logs, ACR, identidade) foi executado com sucesso. O `apply` completo com Key Vault, Cosmos DB e Container App, o deploy da imagem e o teste ponta a ponta com `curl` ainda não foram executados.

## Licença

[MIT](LICENSE)
