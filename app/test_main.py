"""Testes locais: não precisam da Azure (o Cosmos DB é trocado por um fake)."""

import pytest
from fastapi.testclient import TestClient

import main


class FakeContainer:
    def __init__(self):
        self.items = []

    def create_item(self, item):
        self.items.append(item)

    def query_items(self, query, parameters, partition_key):
        return [i for i in self.items if i["userId"] == partition_key]


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "_container", FakeContainer())
    return TestClient(main.app)


def test_health_sem_segredo(client, monkeypatch):
    monkeypatch.delenv("DEMO_API_KEY", raising=False)
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "demo_key_loaded": False}


def test_health_nao_expoe_o_valor_do_segredo(client, monkeypatch):
    monkeypatch.setenv("DEMO_API_KEY", "valor-secreto")
    r = client.get("/health")
    assert r.json()["demo_key_loaded"] is True
    assert "valor-secreto" not in r.text


def test_cria_e_lista_notas_por_usuario(client):
    r = client.post("/notes", json={"user_id": "aluno", "text": "estudar RBAC"})
    assert r.status_code == 201
    assert r.json()["userId"] == "aluno"

    assert len(client.get("/notes", params={"user_id": "aluno"}).json()) == 1
    assert client.get("/notes", params={"user_id": "outro"}).json() == []


def test_nota_sem_usuario_e_rejeitada(client):
    assert client.post("/notes", json={"text": "sem usuario"}).status_code == 422
