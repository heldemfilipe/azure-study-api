import os
import uuid
from datetime import datetime, timezone

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="study-api")
_container = None


def container():
    """Cria o cliente do Cosmos DB na primeira chamada e reaproveita depois.

    DefaultAzureCredential usa a managed identity do Container App (por isso o
    AZURE_CLIENT_ID): sem chave, sem senha, nada de segredo no código.
    O cliente é criado sob demanda para o app subir mesmo sem o banco disponível.
    """
    global _container
    if _container is None:
        client = CosmosClient(
            os.environ["COSMOS_ENDPOINT"], credential=DefaultAzureCredential()
        )
        db = client.get_database_client(os.environ["COSMOS_DATABASE"])
        _container = db.get_container_client("notes")
    return _container


class NoteIn(BaseModel):
    user_id: str
    text: str


@app.get("/health")
def health():
    # Devolve só um booleano: confirma que o segredo chegou do Key Vault, sem
    # nunca expor o valor.
    return {"status": "ok", "demo_key_loaded": bool(os.getenv("DEMO_API_KEY"))}


@app.post("/notes", status_code=201)
def create_note(note: NoteIn):
    item = {
        "id": str(uuid.uuid4()),
        "userId": note.user_id,  # partition key do container
        "text": note.text,
        "createdAt": datetime.now(timezone.utc).isoformat(),
    }
    container().create_item(item)
    return item


@app.get("/notes")
def list_notes(user_id: str):
    return list(
        container().query_items(
            query="SELECT * FROM c WHERE c.userId = @u ORDER BY c.createdAt DESC",
            parameters=[{"name": "@u", "value": user_id}],
            partition_key=user_id,  # consulta de uma partição só: barata
        )
    )
