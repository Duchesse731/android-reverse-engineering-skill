FROM eclipse-temurin:25-jdk-noble
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv python3-pip git cmake ninja-build build-essential pkg-config libicu-dev libcapstone-dev ca-certificates unzip && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir pyelftools==0.32 requests==2.32.5
ENV PATH="/opt/venv/bin:${PATH}" PYTHONUNBUFFERED=1 JAVA_TOOL_OPTIONS="-Xmx1536m"
COPY service/install-tools.py /tmp/install-tools.py
RUN python3 /tmp/install-tools.py
RUN useradd --create-home --uid 10001 analyst && mkdir /data /app && chown -R analyst:analyst /data /opt/tools/blutter
WORKDIR /app
COPY --chown=analyst:analyst service /app/service
USER analyst
ENV PORT=8080 BREAKDOWN_DATA=/data
EXPOSE 8080
CMD ["python3", "service/server.py"]
