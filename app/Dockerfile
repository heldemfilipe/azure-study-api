FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
# Porta 80 de propósito: a imagem de exemplo do primeiro apply também escuta na 80,
# então o ingress do Container App (target_port = 80) serve as duas.
EXPOSE 80
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "80"]
