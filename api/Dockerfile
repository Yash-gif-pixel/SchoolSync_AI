# Written in Phase 0, deployed in Phase 5.
#
# 3.14 to match the interpreter every test has actually run against. It was
# pinned to 3.12 when written, which risked the container hitting syntax or
# library behaviour the local environment never exercised — a difference that
# only ever shows up in the deploy log, at the worst moment.
FROM python:3.14-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Render/Railway/Fly inject $PORT; default to 8000 for local container runs.
ENV PORT=8000
EXPOSE 8000

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]
