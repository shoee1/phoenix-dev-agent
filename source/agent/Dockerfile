FROM python:3.12-slim
ARG CODEX_NPM_PACKAGE=@openai/codex@0.154.0
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git jq xz-utils gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g ${CODEX_NPM_PACKAGE} && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
EXPOSE 8787
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8787"]
