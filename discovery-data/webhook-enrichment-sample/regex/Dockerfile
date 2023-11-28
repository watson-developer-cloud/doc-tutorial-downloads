FROM --platform=linux/amd64 python:3-alpine

WORKDIR /app

COPY requirements.txt main.py /app

RUN pip install --upgrade pip && \
    pip install -r requirements.txt && \
    rm requirements.txt

CMD ["python", "main.py"]
