import pytest
from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


# --- GET / ---

def test_index_status_code(client):
    response = client.get("/")
    assert response.status_code == 200


def test_index_json_content(client):
    response = client.get("/")
    data = response.get_json()
    assert data["message"] == "Hello DevOps"
    assert data["status"] == "ok"


# --- GET /health ---

def test_health_status_code(client):
    response = client.get("/health")
    assert response.status_code == 200


def test_health_json_content(client):
    response = client.get("/health")
    data = response.get_json()
    assert data["status"] == "healthy"


# --- GET /api/hello ---

def test_hello_with_name(client):
    response = client.get("/api/hello?name=Yacine")
    assert response.status_code == 200
    data = response.get_json()
    assert data["message"] == "Hello Yacine"


def test_hello_default_name(client):
    response = client.get("/api/hello")
    data = response.get_json()
    assert data["message"] == "Hello World"


def test_hello_content_type(client):
    response = client.get("/api/hello?name=DevOps")
    assert response.content_type == "application/json"
