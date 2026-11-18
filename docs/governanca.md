# Governança e RBAC mínimo

Quatro ações de baixo custo que mostram maturidade. A atribuição de policy e o lock exigem
permissão de **Owner**, então rode-os com o seu usuário (`az login`), **não pelo pipeline**.
Substitua `<SUB_ID>` e `<ARM_CLIENT_ID>` pelos seus valores (não os publique).

| Ação | O que demonstra | AWS equivalente |
| --- | --- | --- |
| Travar a região | Azure Policy como guarda-corpo | SCP / Config rule de região permitida |
| Proteger o state | Resource lock | S3 Object Lock / proteção contra deleção |
| Revisar permissões | Auditoria de RBAC do pipeline | IAM Access Analyzer |
| Reduzir privilégio | Menor privilégio depois do bootstrap | Remover permissões não usadas da role |

## 1. Travar a região (policy "Allowed locations")

```bash
az policy assignment create \
  --name allowed-locations \
  --scope /subscriptions/<SUB_ID>/resourceGroups/rg-azstudy-dev \
  --policy e56962a6-4747-49cd-b67b-bf8b01975c4c \
  --params '{"listOfAllowedLocations":{"value":["eastus2"]}}'
```

Confira o ID da policy no portal (Policy → Definitions) antes de usar.

## 2. Proteger o state com um lock

```bash
az lock create --name keep-state --lock-type CanNotDelete --resource-group rg-azstudy-tfstate
```

Remova-o só no teardown final (o `scripts/teardown.sh` já tenta removê-lo).

## 3. Revisar as permissões do pipeline

```bash
az role assignment list --all --assignee <ARM_CLIENT_ID> -o table
```

Esperado: `Contributor` e `Role Based Access Control Administrator` no `rg-azstudy-dev`, e
`Storage Blob Data Contributor` na storage account do state. Nada na subscription.

## 4. Reduzir privilégio

O papel `Role Based Access Control Administrator` só é necessário enquanto o Terraform cria
atribuições de papel (AcrPull, Key Vault, Cosmos). Depois que a infraestrutura estabilizar,
retire-o da identidade do pipeline. Em ambiente real, em vez de retirar, **limite-o com
condições** (por exemplo, só permitir atribuir determinados papéis).
