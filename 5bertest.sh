#!/bin/bash
# private-5ber 一键部署升级版
# 适用于 Ubuntu VPS + Cloudflare Flexible HTTPS + Docker
# 域名: wrxilove.dpdns.org
# VPS IP: 98.85.252.221

# -------------------------------
# 配置区
# -------------------------------
DOMAIN="wrxilove.dpdns.org"
ESIM_MASTER_KEY="ChangeMe123456!"   # 强烈建议修改
ADMIN_USER="admin"
ADMIN_PASS="admin123"               # 初始密码，部署后登录修改

# -------------------------------
# 更新系统 & 安装依赖
# -------------------------------
echo "[*] 更新系统..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y curl wget git ufw

# -------------------------------
# 安装 Docker & Docker Compose
# -------------------------------
echo "[*] 安装 Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo systemctl enable docker
sudo systemctl start docker

echo "[*] 安装 Docker Compose..."
DOCKER_COMPOSE_VERSION="2.20.2"
sudo curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# -------------------------------
# 创建项目目录
# -------------------------------
APP_DIR="/opt/private-5ber"
echo "[*] 创建应用目录 $APP_DIR"
sudo mkdir -p $APP_DIR
sudo chown $USER:$USER $APP_DIR
cd $APP_DIR

# -------------------------------
# 创建 Flask 后端文件
# -------------------------------
mkdir -p backend
cat > backend/requirements.txt <<EOL
Flask==2.3.5
Flask-Login==0.6.3
Flask-SQLAlchemy==3.0.5
cryptography==41.0.3
Werkzeug==2.3.6
EOL

cat > backend/crypto.py <<'EOL'
from cryptography.fernet import Fernet
import os

def get_cipher():
    key = os.environ.get("ESIM_MASTER_KEY")
    if not key:
        raise ValueError("ESIM_MASTER_KEY not set")
    return Fernet(key.encode())

def encrypt_file(data: bytes) -> bytes:
    cipher = get_cipher()
    return cipher.encrypt(data)

def decrypt_file(data: bytes) -> bytes:
    cipher = get_cipher()
    return cipher.decrypt(data)
EOL

cat > backend/models.py <<'EOL'
from flask_sqlalchemy import SQLAlchemy
db = SQLAlchemy()

class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), unique=True)
    password = db.Column(db.String(128))

class Profile(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(128))
    filename = db.Column(db.String(128))
    downloads = db.Column(db.Integer, default=0)
    unlimited = db.Column(db.Boolean, default=True)
EOL

cat > backend/app.py <<'EOL'
from flask import Flask, request, send_file, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, login_user, logout_user, login_required, UserMixin
import os
from werkzeug.security import generate_password_hash, check_password_hash
from models import db, User, Profile
from crypto import encrypt_file, decrypt_file

app = Flask(__name__)
app.secret_key = os.urandom(24)
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///data.db'
db.init_app(app)

login_manager = LoginManager()
login_manager.init_app(app)

class AuthUser(UserMixin):
    pass

@login_manager.user_loader
def load_user(user_id):
    user = User.query.get(int(user_id))
    if user:
        u = AuthUser()
        u.id = user.id
        return u
    return None

@app.route("/login", methods=["POST"])
def login():
    data = request.json
    user = User.query.filter_by(username=data.get("username")).first()
    if user and check_password_hash(user.password, data.get("password")):
        u = AuthUser()
        u.id = user.id
        login_user(u)
        return jsonify({"status":"ok"})
    return jsonify({"status":"fail"}),401

@app.route("/logout")
@login_required
def logout():
    logout_user()
    return jsonify({"status":"ok"})

@app.route("/upload", methods=["POST"])
@login_required
def upload():
    f = request.files['file']
    name = request.form.get('name')
    unlimited = request.form.get('unlimited')=="true"
    encrypted = encrypt_file(f.read())
    path = os.path.join("uploads", f.filename)
    os.makedirs("uploads", exist_ok=True)
    with open(path, "wb") as fp:
        fp.write(encrypted)
    profile = Profile(name=name, filename=f.filename, unlimited=unlimited)
    db.session.add(profile)
    db.session.commit()
    return jsonify({"status":"ok"})

@app.route("/download/<int:pid>")
@login_required
def download(pid):
    profile = Profile.query.get(pid)
    if not profile:
        return "Not found",404
    path = os.path.join("uploads", profile.filename)
    with open(path,"rb") as fp:
        data = decrypt_file(fp.read())
    if not profile.unlimited:
        if profile.downloads>=1:
            return "Download limit reached",403
        profile.downloads+=1
        db.session.commit()
    return send_file(
        path,
        as_attachment=True,
        download_name=profile.filename
    )

if __name__=="__main__":
    os.makedirs("uploads", exist_ok=True)
    with app.app_context():
        db.create_all()
        if not User.query.filter_by(username="admin").first():
            u = User(username="admin", password=generate_password_hash("admin123"))
            db.session.add(u)
            db.session.commit()
    app.run(host="0.0.0.0", port=5000)
EOL

cat > backend/Dockerfile <<EOL
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
ENV ESIM_MASTER_KEY=${ESIM_MASTER_KEY}
EXPOSE 5000
CMD ["python","app.py"]
EOL

# -------------------------------
# Docker Compose & Nginx
# -------------------------------
cat > docker-compose.yml <<EOL
version: "3"
services:
  web:
    build: ./backend
    container_name: private5ber_web
    environment:
      - ESIM_MASTER_KEY=${ESIM_MASTER_KEY}
    ports:
      - "5000:5000"
    volumes:
      - ./backend/uploads:/app/uploads
      - ./backend/data.db:/app/data.db

  nginx:
    image: nginx:stable-alpine
    container_name: private5ber_nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL

mkdir -p nginx
cat > nginx/nginx.conf <<EOL
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://web:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOL

# -------------------------------
# 启动服务
# -------------------------------
echo "[*] 启动 Docker Compose 服务..."
sudo docker-compose up -d --build

echo "[*] 部署完成！"
echo "[*] 访问地址：https://${DOMAIN} （Cloudflare Flexible HTTPS）"
echo "[*] 默认管理员账号 / 密码: ${ADMIN_USER} / ${ADMIN_PASS}"
echo "[*] 请首次登录后修改密码，并修改 ESIM_MASTER_KEY 为强密钥"
