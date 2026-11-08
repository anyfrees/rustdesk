FROM python:3.12-alpine AS dependencies
RUN apk upgrade --no-cache
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

FROM dependencies AS test
COPY . .
USER 10001:10001
RUN python -m unittest discover -p 'test_*.py'

FROM dependencies AS release
ARG VCS_REF=unknown
LABEL org.opencontainers.image.source="https://cnb.cool/nnu/rustdesk-server" org.opencontainers.image.revision=$VCS_REF
RUN python -m pip uninstall -y pip
COPY app.py release.py accounts.py reset_account.py delegation.py external_download.py announcements.py platform_release.py platforms.py retention.py download_portal.py login_guard.py mobile_import.py ./
COPY static ./static
COPY portal-static ./portal-static
USER 10001:10001
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", "--timeout", "600", "--umask", "0022", "--no-control-socket", "--worker-tmp-dir", "/tmp", "app:app"]
