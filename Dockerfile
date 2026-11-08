FROM python:3.11-slim-bookworm

# Java (obligatoire pour Spark) + outils système
RUN apt-get update && apt-get install -y --no-install-recommends \
    default-jre-headless procps \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/default-java

RUN pip install --upgrade pip

# Les petits paquets d'abord
RUN pip install --default-timeout=1000 --retries 10 pandas matplotlib

# JupyterLab
RUN pip install --default-timeout=1000 --retries 10 jupyterlab

# PySpark depuis le fichier téléchargé en local (pas de téléchargement réseau)
COPY wheels/ /tmp/wheels/
RUN pip install /tmp/wheels/pyspark-3.5.0.tar.gz

WORKDIR /home/work
EXPOSE 8888 4040

CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", \
     "--allow-root", "--IdentityProvider.token=", "--ServerApp.root_dir=/home/work"]