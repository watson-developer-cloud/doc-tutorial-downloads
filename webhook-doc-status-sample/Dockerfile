FROM --platform=linux/amd64 python:3-alpine

WORKDIR /app

COPY requirements.txt ./

RUN pip install --upgrade pip && \
    pip install -r requirements.txt && \
    rm requirements.txt

COPY main.py ./

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]