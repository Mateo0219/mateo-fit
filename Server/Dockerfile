FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app/Server
COPY Server/requirements.txt Server/requirements-production.txt ./
RUN pip install --no-cache-dir -r requirements-production.txt && useradd --uid 10001 --create-home mateo
COPY Server/ /app/Server/
COPY AgentResources/ /app/AgentResources/
RUN mkdir /data && chown 10001:10001 /data
USER 10001:10001
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/health', timeout=2)"
CMD ["uvicorn","service:app","--host","0.0.0.0","--port","8787","--workers","1","--no-access-log","--timeout-keep-alive","5"]
