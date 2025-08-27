#!/bin/bash

# 私有eSIM服务器一键部署脚本
# 作者: eSIM Server Team
# 版本: 1.0
# 更新日期: 2025-08-27

# 设置变量
DOMAIN="wrxilove.dpdns.org"
IP="54.224.221.214"
WEB_PORT="28889"
SMDP_PORT="29998"
DB_PASS=$(openssl rand -base64 32)
PROJECT_DIR="/opt/esim-server"
DOCKER_COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
NGINX_CONF="/etc/nginx/sites-available/esim-server"
ENV_FILE="$PROJECT_DIR/.env"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
    exit 1
}

# 环境检测函数
check_environment() {
    log "开始环境检测..."
    
    # 检查操作系统
    if [[ ! -f /etc/os-release ]]; then
        error "无法检测操作系统版本"
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        error "此脚本仅支持Ubuntu系统"
    fi
    log "操作系统: $PRETTY_NAME"
    
    # 检查架构
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        warn "检测到架构: $ARCH，推荐使用x86_64架构"
    fi
    
    # 检查内存
    MEM=$(free -m | awk 'NR==2{printf "%.1f", $2/1024}')
    if (( $(echo "$MEM < 1.0" | bc -l) )); then
        error "内存不足，至少需要1GB内存"
    fi
    log "内存: ${MEM}GB"
    
    # 检查磁盘空间
    DISK=$(df -h / | awk 'NR==2{print $4}')
    if [[ "$DISK" == *G ]]; then
        DISK_GB=$(echo $DISK | sed 's/G//')
        if (( $(echo "$DISK_GB < 5" | bc -l) )); then
            error "磁盘空间不足，至少需要5GB可用空间"
        fi
    fi
    log "可用磁盘空间: $DISK"
    
    # 检查网络连接
    if ! ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        error "网络连接不可用"
    fi
    log "网络连接: 正常"
    
    # 检查端口占用
    if netstat -tuln | grep -q ":$WEB_PORT "; then
        error "端口 $WEB_PORT 已被占用"
    fi
    if netstat -tuln | grep -q ":$SMDP_PORT "; then
        error "端口 $SMDP_PORT 已被占用"
    fi
    log "端口检查: $WEB_PORT 和 $SMDP_PORT 可用"
    
    # 检查域名解析
    if ! nslookup "$DOMAIN" | grep -q "$IP"; then
        warn "域名 $DOMAIN 未解析到 $IP，请检查DNS配置"
    else
        log "域名解析: $DOMAIN -> $IP"
    fi
    
    log "环境检测完成"
}

# 安装依赖函数
install_dependencies() {
    log "安装系统依赖..."
    
    # 更新系统
    apt-get update -y
    apt-get upgrade -y
    
    # 安装基础工具
    apt-get install -y \
        curl \
        wget \
        git \
        unzip \
        nginx \
        certbot \
        python3-certbot-nginx \
        bc \
        jq
    
    # 安装Docker
    if ! command -v docker &> /dev/null; then
        log "安装Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        usermod -aG docker $USER
        systemctl enable docker
        systemctl start docker
    fi
    
    # 安装Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        log "安装Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    log "依赖安装完成"
}

# 创建项目目录
create_project_structure() {
    log "创建项目目录结构..."
    
    mkdir -p $PROJECT_DIR/{web,smdp,uploads,logs}
    mkdir -p $PROJECT_DIR/web/{templates,static}
    mkdir -p $PROJECT_DIR/smdp
    
    # 设置权限
    chown -R $USER:$USER $PROJECT_DIR
    chmod -R 755 $PROJECT_DIR
}

# 生成Docker Compose文件
generate_docker_compose() {
    log "生成Docker Compose配置..."
    
    cat > $DOCKER_COMPOSE_FILE <<EOF
version: '3.8'

services:
  db:
    image: mysql:8.0
    container_name: esim-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: $DB_PASS
      MYSQL_DATABASE: esim_server
      MYSQL_USER: esim_user
      MYSQL_PASSWORD: $DB_PASS
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - esim-network
    command: --default-authentication-plugin=mysql_native_password

  web:
    build: ./web
    container_name: esim-web
    restart: unless-stopped
    ports:
      - "$WEB_PORT:5000"
    volumes:
      - $PROJECT_DIR/uploads:/app/uploads
      - $PROJECT_DIR/logs:/app/logs
    environment:
      DB_HOST: db
      DB_USER: esim_user
      DB_PASSWORD: $DB_PASS
      DB_NAME: esim_server
    depends_on:
      - db
    networks:
      - esim-network

  smdp:
    build: ./smdp
    container_name: esim-smdp
    restart: unless-stopped
    ports:
      - "$SMDP_PORT:5000"
    volumes:
      - $PROJECT_DIR/uploads:/app/uploads
      - $PROJECT_DIR/logs:/app/logs
    environment:
      DB_HOST: db
      DB_USER: esim_user
      DB_PASSWORD: $DB_PASS
      DB_NAME: esim_server
    depends_on:
      - db
    networks:
      - esim-network

volumes:
  db_data:

networks:
  esim-network:
    driver: bridge
EOF
}

# 生成Web应用Dockerfile
generate_web_dockerfile() {
    cat > $PROJECT_DIR/web/Dockerfile <<EOF
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
EOF
}

# 生成Web应用requirements.txt
generate_web_requirements() {
    cat > $PROJECT_DIR/web/requirements.txt <<EOF
Flask==2.0.1
Flask-SQLAlchemy==2.5.1
Flask-Migrate==3.1.0
Werkzeug==2.0.1
PyMySQL==1.0.2
python-dotenv==0.19.0
gunicorn==20.1.0
EOF
}

# 生成Web应用app.py
generate_web_app() {
    cat > $PROJECT_DIR/web/app.py <<EOF
import os
from flask import Flask, render_template, request, redirect, url_for, flash, send_from_directory
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from werkzeug.utils import secure_filename
import uuid
import datetime

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'dev-secret-key')
app.config['SQLALCHEMY_DATABASE_URI'] = f"mysql+pymysql://{os.environ.get('DB_USER')}:{os.environ.get('DB_PASSWORD')}@{os.environ.get('DB_HOST')}/{os.environ.get('DB_NAME')}"
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = '/app/uploads'
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max file size

db = SQLAlchemy(app)
migrate = Migrate(app, db)

class EsimProfile(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(255), nullable=False)
    original_name = db.Column(db.String(255), nullable=False)
    activation_code = db.Column(db.String(64), unique=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.datetime.utcnow)
    downloaded = db.Column(db.Boolean, default=False)

    def __repr__(self):
        return f'<EsimProfile {self.filename}>'

@app.route('/')
def index():
    profiles = EsimProfile.query.order_by(EsimProfile.created_at.desc()).all()
    return render_template('index.html', profiles=profiles)

@app.route('/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        flash('No file part')
        return redirect(request.url)
    
    file = request.files['file']
    if file.filename == '':
        flash('No selected file')
        return redirect(request.url)
    
    if file:
        filename = secure_filename(file.filename)
        unique_filename = f"{uuid.uuid4().hex}_{filename}"
        activation_code = str(uuid.uuid4())
        
        file_path = os.path.join(app.config['UPLOAD_FOLDER'], unique_filename)
        file.save(file_path)
        
        new_profile = EsimProfile(
            filename=unique_filename,
            original_name=filename,
            activation_code=activation_code
        )
        db.session.add(new_profile)
        db.session.commit()
        
        flash(f'File uploaded successfully! Activation code: {activation_code}')
        return redirect(url_for('index'))

@app.route('/download/<activation_code>')
def download_file(activation_code):
    profile = EsimProfile.query.filter_by(activation_code=activation_code).first()
    if not profile:
        flash('Invalid activation code')
        return redirect(url_for('index'))
    
    profile.downloaded = True
    db.session.commit()
    
    return send_from_directory(app.config['UPLOAD_FOLDER'], profile.filename, as_attachment=True, download_name=profile.original_name)

@app.route('/delete/<int:profile_id>')
def delete_profile(profile_id):
    profile = EsimProfile.query.get_or_404(profile_id)
    
    # Delete file from filesystem
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], profile.filename)
    if os.path.exists(file_path):
        os.remove(file_path)
    
    # Delete from database
    db.session.delete(profile)
    db.session.commit()
    
    flash('Profile deleted successfully')
    return redirect(url_for('index'))

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(host='0.0.0.0', port=5000, debug=True)
EOF
}

# 生成Web模板
generate_web_templates() {
    # index.html
    cat > $PROJECT_DIR/web/templates/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Private eSIM Server</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body>
    <div class="container">
        <h1>Private eSIM Server</h1>
        
        {% with messages = get_flashed_messages() %}
            {% if messages %}
                <div class="flash-messages">
                    {% for message in messages %}
                        <div class="flash-message">{{ message }}</div>
                    {% endfor %}
                </div>
            {% endif %}
        {% endwith %}
        
        <div class="upload-section">
            <h2>Upload eSIM Profile</h2>
            <form method="post" enctype="multipart/form-data" action="{{ url_for('upload_file') }}">
                <div class="form-group">
                    <label for="file">Select eSIM Profile (.esim):</label>
                    <input type="file" name="file" id="file" accept=".esim" required>
                </div>
                <button type="submit" class="btn">Upload</button>
            </form>
        </div>
        
        <div class="profiles-section">
            <h2>Uploaded Profiles</h2>
            {% if profiles %}
                <table class="profiles-table">
                    <thead>
                        <tr>
                            <th>Filename</th>
                            <th>Activation Code</th>
                            <th>Created</th>
                            <th>Downloaded</th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for profile in profiles %}
                            <tr>
                                <td>{{ profile.original_name }}</td>
                                <td>{{ profile.activation_code }}</td>
                                <td>{{ profile.created_at.strftime('%Y-%m-%d %H:%M') }}</td>
                                <td>{{ 'Yes' if profile.downloaded else 'No' }}</td>
                                <td>
                                    <a href="{{ url_for('download_file', activation_code=profile.activation_code) }}" class="btn btn-small">Download</a>
                                    <a href="{{ url_for('delete_profile', profile_id=profile.id) }}" class="btn btn-small btn-danger" onclick="return confirm('Are you sure?')">Delete</a>
                                </td>
                            </tr>
                        {% endfor %}
                    </tbody>
                </table>
            {% else %}
                <p>No profiles uploaded yet.</p>
            {% endif %}
        </div>
    </div>
</body>
</html>
EOF

    # style.css
    cat > $PROJECT_DIR/web/static/style.css <<EOF
body {
    font-family: Arial, sans-serif;
    line-height: 1.6;
    margin: 0;
    padding: 0;
    background-color: #f4f4f4;
    color: #333;
}

.container {
    max-width: 1000px;
    margin: 20px auto;
    padding: 20px;
    background-color: #fff;
    border-radius: 5px;
    box-shadow: 0 0 10px rgba(0, 0, 0, 0.1);
}

h1, h2 {
    color: #2c3e50;
    border-bottom: 2px solid #3498db;
    padding-bottom: 10px;
}

.flash-messages {
    margin-bottom: 20px;
}

.flash-message {
    padding: 10px;
    background-color: #d4edda;
    color: #155724;
    border-radius: 4px;
    margin-bottom: 10px;
}

.upload-section, .profiles-section {
    margin-bottom: 30px;
}

.form-group {
    margin-bottom: 15px;
}

label {
    display: block;
    margin-bottom: 5px;
    font-weight: bold;
}

input[type="file"] {
    display: block;
    width: 100%;
    padding: 8px;
    border: 1px solid #ddd;
    border-radius: 4px;
}

.btn {
    display: inline-block;
    background-color: #3498db;
    color: white;
    padding: 10px 15px;
    border: none;
    border-radius: 4px;
    cursor: pointer;
    text-decoration: none;
    font-size: 14px;
}

.btn:hover {
    background-color: #2980b9;
}

.btn-small {
    padding: 5px 10px;
    font-size: 12px;
    margin-right: 5px;
}

.btn-danger {
    background-color: #e74c3c;
}

.btn-danger:hover {
    background-color: #c0392b;
}

.profiles-table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 20px;
}

.profiles-table th, .profiles-table td {
    padding: 12px 15px;
    text-align: left;
    border-bottom: 1px solid #ddd;
}

.profiles-table th {
    background-color: #f8f9fa;
    font-weight: bold;
}

.profiles-table tr:hover {
    background-color: #f1f1f1;
}
EOF
}

# 生成SM-DP服务Dockerfile
generate_smdp_dockerfile() {
    cat > $PROJECT_DIR/smdp/Dockerfile <<EOF
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
EOF
}

# 生成SM-DP服务requirements.txt
generate_smdp_requirements() {
    cat > $PROJECT_DIR/smdp/requirements.txt <<EOF
Flask==2.0.1
Flask-SQLAlchemy==2.5.1
Werkzeug==2.0.1
PyMySQL==1.0.2
python-dotenv==0.19.0
gunicorn==20.1.0
EOF
}

# 生成SM-DP服务app.py
generate_smdp_app() {
    cat > $PROJECT_DIR/smdp/app.py <<EOF
import os
from flask import Flask, request, jsonify, send_from_directory
from flask_sqlalchemy import SQLAlchemy
import uuid

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = f"mysql+pymysql://{os.environ.get('DB_USER')}:{os.environ.get('DB_PASSWORD')}@{os.environ.get('DB_HOST')}/{os.environ.get('DB_NAME')}"
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = '/app/uploads'

db = SQLAlchemy(app)

class EsimProfile(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(255), nullable=False)
    original_name = db.Column(db.String(255), nullable=False)
    activation_code = db.Column(db.String(64), unique=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.datetime.utcnow)
    downloaded = db.Column(db.Boolean, default=False)

@app.route('/download/<activation_code>', methods=['GET'])
def download_profile(activation_code):
    profile = EsimProfile.query.filter_by(activation_code=activation_code).first()
    if not profile:
        return jsonify({"error": "Invalid activation code"}), 404
    
    profile.downloaded = True
    db.session.commit()
    
    return send_from_directory(app.config['UPLOAD_FOLDER'], profile.filename, as_attachment=True, download_name=profile.original_name)

@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({"status": "healthy"})

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(host='0.0.0.0', port=5000)
EOF
}

# 生成Nginx配置
generate_nginx_config() {
    cat > $NGINX_CONF <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    # Web管理界面
    location / {
        proxy_pass http://127.0.0.1:$WEB_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # SM-DP服务
    location /smdp/ {
        proxy_pass http://127.0.0.1:$SMDP_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
}

# 生成环境文件
generate_env_file() {
    cat > $ENV_FILE <<EOF
# Database Configuration
DB_HOST=db
DB_USER=esim_user
DB_PASSWORD=$DB_PASS
DB_NAME=esim_server

# Application Configuration
SECRET_KEY=$(openssl rand -base64 32)
FLASK_ENV=production
EOF
}

# 获取SSL证书
get_ssl_certificate() {
    log "获取SSL证书..."
    
    # 创建证书目录
    mkdir -p /var/www/certbot
    mkdir -p /etc/letsencrypt/live/$DOMAIN
    
    # 启动临时Nginx获取证书
    systemctl start nginx
    
    # 获取证书
    certbot certonly --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
    
    # 停止临时Nginx
    systemctl stop nginx
}

# 启动服务
start_services() {
    log "启动服务..."
    
    # 启动Docker Compose服务
    cd $PROJECT_DIR
    docker-compose up -d
    
    # 等待服务启动
    sleep 10
    
    # 启动Nginx
    systemctl enable nginx
    systemctl start nginx
    
    log "服务启动完成"
}

# 主函数
main() {
    log "开始部署私有eSIM服务器..."
    
    # 环境检测
    check_environment
    
    # 安装依赖
    install_dependencies
    
    # 创建项目结构
    create_project_structure
    
    # 生成配置文件
    generate_docker_compose
    generate_web_dockerfile
    generate_web_requirements
    generate_web_app
    generate_web_templates
    generate_smdp_dockerfile
    generate_smdp_requirements
    generate_smdp_app
    generate_nginx_config
    generate_env_file
    
    # 获取SSL证书
    get_ssl_certificate
    
    # 启动服务
    start_services
    
    log "部署完成！"
    log "Web管理界面: https://$DOMAIN:$WEB_PORT"
    log "SM-DP服务: https://$DOMAIN:$SMDP_PORT/smdp/"
    log "数据库密码: $DB_PASS"
    log "请妥善保存数据库密码！"
}

# 执行主函数
main
