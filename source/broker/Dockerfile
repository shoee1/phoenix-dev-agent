FROM python:3.12-slim-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq docker.io \
 && test -x /usr/bin/docker \
 && /usr/bin/docker --version \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY broker.py .
EXPOSE 8790
CMD ["uvicorn","broker:app","--host","0.0.0.0","--port","8790"]
