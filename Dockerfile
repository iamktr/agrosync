FROM python:3.11-slim
WORKDIR /app

# 1. Create a virtual environment inside the container
RUN python -m venv /opt/venv
# 2. Tell the container to use the virtual environment's path
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
# 3. Pip install now runs safely inside the venv, silencing the warning
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 app:app
