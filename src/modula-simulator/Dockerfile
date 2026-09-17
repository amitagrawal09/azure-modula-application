FROM python:3.12-slim
WORKDIR /app
COPY simulator.py .
# stdlib only — no pip install needed
ENV MODE=api RATE_PER_MIN=12 DURATION_SEC=0
CMD ["python", "-u", "simulator.py"]
