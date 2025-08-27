#!/bin/bash

# 私有eSIM服务器一键部署脚本
# 作者: eSIM Server Team
# 版本: 1.2
# 更新日期: 2025-08-27

# 设置变量
DOMAIN="wrxilove.dpdns.org"
IP="54.224.221.214"
WEBPORT="28889"
SMDPPORT="29998"
DBPASS=$(openssl rand -base64 32)
PROJECTDIR="/opt/esim-server"
DOCKERCOMPOSEFILE="$PROJECTDIR/docker-compose.yml"
ENVFILE="$PROJECTDIR/.env"
NGINXCONF="/etc/nginx/sites-available/esim-server"
CERTBOTDIR="/etc/letsencrypt/live/$DOMAIN"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "${GREEN}开始部署私有eSIM服务器...${NC}"

# 环境检测
log "${YELLOW}开始环境检测...${NC}"

# 检测操作系统
OS=$(lsb_release -si)
OS_VERSION=$(lsb_release -sr)
log "操作系统: $OS $OS_VERSION"

if [ "$OS" != "Ubuntu" ]; then
    log "${RED}错误: 此脚本仅支持Ubuntu系统${NC}"
    exit 1
fi

# 检测内存 - 修改为更合理的检测逻辑
TOTAL_MEM=$(free -m | awk '/Mem:/ {print $2}')
AVAILABLE_MEM=$(free -m | awk '/Mem:/ {print $7}')

log "总内存: ${TOTAL_MEM}MB"
log "可用内存: ${AVAILABLE_MEM}MB"

if [ "$TOTAL_MEM" -lt 512 ]; then
    log "${RED}错误: 内存不足，至少需要512MB内存${NC}"
    exit 1
elif [ "$TOTAL_MEM" -lt 1024 ]; then
    log "${YELLOW}警告: 内存小于1GB，但可用内存足够，继续安装...${NC}"
fi

# 检测磁盘空间
DISK_AVAILABLE=$(df -m / | awk 'NR==2 {print $4}')
log "可用磁盘空间: ${DISK_AVAILABLE}MB"

if [ "$DISK_AVAILABLE" -lt 2048 ]; then
    log "${RED}错误: 磁盘空间不足，至少需要2GB可用空间${NC}"
    exit 1
fi

# 检测网络连接
if ! ping -c 1 -W 5 github.com > /dev/null 2>&1; then
    log "${RED}错误: 无法连接到GitHub，请检查网络连接${NC}"
    exit 1
fi

log "${GREEN}环境检测完成${NC}"

# 更新系统
log "${YELLOW}更新系统...${NC}"
apt-get update -y
apt-get upgrade -y

# 安装必要软件
log "${YELLOW}安装必要软件...${NC}"
apt-get install -y docker.io docker-compose nginx certbot python3-certbot-nginx git curl unzip

# 启动Docker
systemctl enable docker
systemctl start docker

# 创建项目目录
log "${YELLOW}创建项目目录...${NC}"
mkdir -p $PROJECTDIR
cd $PROJECTDIR

# 创建docker-compose.yml
log "${YELLOW}创建Docker Compose配置...${NC}"
cat > $DOCKERCOMPOSEFILE <<EOF
version: '3'

services:
  db:
    image: mysql:5.7
    container_name: esim-db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $DBPASS
      MYSQL_DATABASE: esim
      MYSQL_USER: esim
      MYSQL_PASSWORD: $DBPASS
    volumes:
      - db_data:/var/lib/mysql
    command: --max_allowed_packet=64M
    mem_limit: 256m

  web:
    build: ./web
    container_name: esim-web
    restart: always
    ports:
      - "$WEBPORT:5000"
    volumes:
      - ./web:/app
      - ./uploads:/app/uploads
    depends_on:
      - db
    environment:
      FLASK_APP: app.py
      FLASK_ENV: production
      DATABASE_URL: mysql+pymysql://esim:$DBPASS@db:3306/esim
      SECRET_KEY: $(openssl rand -hex 32)
    mem_limit: 256m

  smdp:
    build: ./smdp
    container_name: esim-smdp
    restart: always
    ports:
      - "$SMDPPORT:8080"
    volumes:
      - ./smdp:/app
      - ./profiles:/app/profiles
    depends_on:
      - db
    environment:
      DATABASE_URL: mysql+pymysql://esim:$DBPASS@db:3306/esim
      SECRET_KEY: $(openssl rand -hex 32)
    mem_limit: 256m

volumes:
  db_data:
EOF

# 创建.env文件
log "${YELLOW}创建环境变量文件...${NC}"
cat > $ENVFILE <<EOF
DOMAIN=$DOMAIN
IP=$IP
WEBPORT=$WEBPORT
SMDPPORT=$SMDPPORT
DBPASS=$DBPASS
EOF

# 创建Web应用目录
log "${YELLOW}创建Web应用...${NC}"
mkdir -p web uploads
cd web

# 创建Web应用的Dockerfile
cat > Dockerfile <<EOF
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
EOF

# 创建requirements.txt
cat > requirements.txt <<EOF
Flask==2.0.1
Flask-SQLAlchemy==2.5.1
Flask-Migrate==3.1.0
PyMySQL==1.0.2
gunicorn==20.1.0
Werkzeug==2.0.1
python-dotenv==0.19.0
EOF

# 创建Web应用
cat > app.py <<EOF
from flask import Flask, render_template, request, redirect, url_for, flash, send_file
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
import os
import uuid
import secrets
from werkzeug.utils import secure_filename
from datetime import datetime

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'dev-secret-key')
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('DATABASE_URL', 'sqlite:///esim.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = 'uploads'
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max file size

db = SQLAlchemy(app)
migrate = Migrate(app, db)

# 数据库模型
class EsimProfile(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(255), nullable=False)
    original_name = db.Column(db.String(255), nullable=False)
    activation_code = db.Column(db.String(64), unique=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    downloads = db.Column(db.Integer, default=0)
    is_active = db.Column(db.Boolean, default=True)

    def __repr__(self):
        return f'<EsimProfile {self.filename}>'

# 创建数据库表
with app.app_context():
    db.create_all()

# 路由
@app.route('/')
def index():
    profiles = EsimProfile.query.filter_by(is_active=True).all()
    return render_template('index.html', profiles=profiles)

@app.route('/upload', methods=['GET', 'POST'])
def upload_file():
    if request.method == 'POST':
        if 'file' not in request.files:
            flash('没有文件部分')
            return redirect(request.url)
        
        file = request.files['file']
        if file.filename == '':
            flash('没有选择文件')
            return redirect(request.url)
        
        if file:
            filename = secure_filename(file.filename)
            unique_filename = f"{uuid.uuid4().hex}_{filename}"
            file_path = os.path.join(app.config['UPLOAD_FOLDER'], unique_filename)
            file.save(file_path)
            
            # 生成激活码
            activation_code = secrets.token_urlsafe(16)
            
            # 保存到数据库
            new_profile = EsimProfile(
                filename=unique_filename,
                original_name=filename,
                activation_code=activation_code
            )
            db.session.add(new_profile)
            db.session.commit()
            
            flash('文件上传成功！')
            return redirect(url_for('index'))
    
    return render_template('upload.html')

@app.route('/download/<activation_code>')
def download_file(activation_code):
    profile = EsimProfile.query.filter_by(activation_code=activation_code, is_active=True).first_or_404()
    
    # 增加下载计数
    profile.downloads += 1
    db.session.commit()
    
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], profile.filename)
    return send_file(file_path, as_attachment=True, download_name=profile.original_name)

@app.route('/delete/<int:profile_id>')
def delete_profile(profile_id):
    profile = EsimProfile.query.get_or_404(profile_id)
    
    # 删除文件
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], profile.filename)
    if os.path.exists(file_path):
        os.remove(file_path)
    
    # 从数据库删除
    db.session.delete(profile)
    db.session.commit()
    
    flash('配置文件已删除')
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(debug=False, host='0.0.0.0', port=5000)
EOF

# 创建模板目录和文件
mkdir -p templates static/css static/js

# 创建基础模板
cat > templates/base.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>私有eSIM服务器</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-dark bg-dark">
        <div class="container">
            <a class="navbar-brand" href="{{ url_for('index') }}">私有eSIM服务器</a>
            <div class="collapse navbar-collapse">
                <ul class="navbar-nav ms-auto">
                    <li class="nav-item">
                        <a class="nav-link" href="{{ url_for('upload_file') }}">上传配置文件</a>
                    </li>
                </ul>
            </div>
        </div>
    </nav>

    <div class="container mt-4">
        {% with messages = get_flashed_messages() %}
            {% if messages %}
                {% for message in messages %}
                    <div class="alert alert-info alert-dismissible fade show" role="alert">
                        {{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}

        {% block content %}{% endblock %}
    </div>

    <footer class="bg-dark text-white text-center py-3 mt-5">
        <div class="container">
            <p>私有eSIM服务器 &copy; 2025</p>
        </div>
    </footer>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# 创建首页模板
cat > templates/index.html <<EOF
{% extends "base.html" %}

{% block content %}
<div class="row">
    <div class="col-md-12">
        <h1 class="mb-4">eSIM配置文件管理</h1>
        
        <div class="card mb-4">
            <div class="card-header">
                <h5>现有配置文件</h5>
            </div>
            <div class="card-body">
                {% if profiles %}
                    <div class="table-responsive">
                        <table class="table table-striped">
                            <thead>
                                <tr>
                                    <th>文件名</th>
                                    <th>激活码</th>
                                    <th>创建时间</th>
                                    <th>下载次数</th>
                                    <th>操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                {% for profile in profiles %}
                                <tr>
                                    <td>{{ profile.original_name }}</td>
                                    <td><code>{{ profile.activation_code }}</code></td>
                                    <td>{{ profile.created_at.strftime('%Y-%m-%d %H:%M') }}</td>
                                    <td>{{ profile.downloads }}</td>
                                    <td>
                                        <a href="{{ url_for('delete_profile', profile_id=profile.id) }}" class="btn btn-sm btn-danger" onclick="return confirm('确定要删除这个配置文件吗？')">删除</a>
                                    </td>
                                </tr>
                                {% endfor %}
                            </tbody>
                        </table>
                    </div>
                {% else %}
                    <p class="text-muted">暂无配置文件，请<a href="{{ url_for('upload_file') }}">上传</a>新的配置文件。</p>
                {% endif %}
            </div>
        </div>
        
        <div class="card">
            <div class="card-header">
                <h5>使用说明</h5>
            </div>
            <div class="card-body">
                <ol>
                    <li>上传原始eSIM配置文件（非5ber封装后的文件）</li>
                    <li>系统会为每个配置文件生成唯一激活码</li>
                    <li>在设备上输入SM-DP地址: <code>{{ request.host_url }}smdp/</code></li>
                    <li>输入激活码下载配置文件</li>
                    <li>可随时删除配置文件</li>
                </ol>
            </div>
        </div>
    </div>
</div>
{% endblock %}
EOF

# 创建上传页面模板
cat > templates/upload.html <<EOF
{% extends "base.html" %}

{% block content %}
<div class="row">
    <div class="col-md-8 offset-md-2">
        <h1 class="mb-4">上传eSIM配置文件</h1>
        
        <div class="card">
            <div class="card-body">
                <form method="post" enctype="multipart/form-data">
                    <div class="mb-3">
                        <label for="file" class="form-label">选择eSIM配置文件</label>
                        <input type="file" class="form-control" id="file" name="file" required>
                        <div class="form-text">请上传原始eSIM配置文件（.esim或.der格式），而非5ber封装后的文件。</div>
                    </div>
                    <button type="submit" class="btn btn-primary">上传</button>
                    <a href="{{ url_for('index') }}" class="btn btn-secondary">取消</a>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
EOF

# 创建CSS文件
cat > static/css/style.css <<EOF
body {
    background-color: #f8f9fa;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
}

footer {
    margin-top: auto;
}

.navbar-brand {
    font-weight: bold;
}

.card {
    box-shadow: 0 0.125rem 0.25rem rgba(0, 0, 0, 0.075);
    border: 1px solid rgba(0, 0, 0, 0.125);
}

.table th {
    background-color: #f8f9fa;
}

code {
    background-color: #e9ecef;
    padding: 0.2rem 0.4rem;
    border-radius: 0.25rem;
    font-size: 0.9em;
}
EOF

# 返回项目目录
cd $PROJECTDIR

# 创建SM-DP服务目录
log "${YELLOW}创建SM-DP服务...${NC}"
mkdir -p smdp profiles
cd smdp

# 创建SM-DP服务的Dockerfile
cat > Dockerfile <<EOF
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
EOF

# 创建SM-DP服务的requirements.txt
cat > requirements.txt <<EOF
Flask==2.0.1
Flask-SQLAlchemy==2.5.1
PyMySQL==1.0.2
gunicorn==20.1.0
python-dotenv==0.19.0
EOF

# 创建SM-DP服务应用
cat > app.py <<EOF
from flask import Flask, request, jsonify, send_file
from flask_sqlalchemy import SQLAlchemy
import os
from datetime import datetime

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('DATABASE_URL', 'sqlite:///esim.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)

# 导入Web应用的数据库模型
from web.app import EsimProfile

# SM-DP+ API端点
@app.route('/gsma/rsp2/es2plus/download', methods=['POST'])
def download():
    data = request.json
    
    # 验证请求
    if not data or 'eid' not in data or 'matchingId' not in data:
        return jsonify({'error': 'Invalid request'}), 400
    
    # 查找配置文件
    profile = EsimProfile.query.filter_by(activation_code=data['matchingId'], is_active=True).first()
    
    if not profile:
        return jsonify({'error': 'Profile not found'}), 404
    
    # 增加下载计数
    profile.downloads += 1
    db.session.commit()
    
    # 返回配置文件
    file_path = os.path.join('../uploads', profile.filename)
    if os.path.exists(file_path):
        return send_file(file_path, as_attachment=True, download_name=profile.original_name)
    else:
        return jsonify({'error': 'File not found'}), 404

# 健康检查端点
@app.route('/health')
def health():
    return jsonify({'status': 'ok'})

if __name__ == '__main__':
    app.run(debug=False, host='0.0.0.0', port=8080)
EOF

# 返回项目目录
cd $PROJECTDIR

# 配置Nginx
log "${YELLOW}配置Nginx...${NC}"
cat > $NGINXCONF <<EOF
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
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERTBOTDIR/fullchain.pem;
    ssl_certificate_key $CERTBOTDIR/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Web应用
    location / {
        proxy_pass http://127.0.0.1:$WEBPORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # SM-DP服务
    location /smdp/ {
        proxy_pass http://127.0.0.1:$SMDPPORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# 启用Nginx配置
ln -sf $NGINXCONF /etc/nginx/sites-enabled/

# 创建证书目录
mkdir -p /var/www/certbot

# 获取SSL证书
log "${YELLOW}获取SSL证书...${NC}"
certbot --nginx -d $DOMAIN --email admin@$DOMAIN --agree-tos --no-eff-email --keep-until-expiring

# 启动服务
log "${YELLOW}启动服务...${NC}"
cd $PROJECTDIR
docker-compose up -d

# 重启Nginx
systemctl restart nginx

# 创建系统服务
log "${YELLOW}创建系统服务...${NC}"
cat > /etc/systemd/system/esim-server.service <<EOF
[Unit]
Description=eSIM Server
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECTDIR
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

# 启用服务
systemctl enable esim-server

# 完成提示
log "${GREEN}部署完成！${NC}"
log "${GREEN}Web管理界面: https://$DOMAIN${NC}"
log "${GREEN}SM-DP服务: https://$DOMAIN/smdp/${NC}"
log "${GREEN}数据库密码已保存到 $ENVFILE${NC}"
log "${YELLOW}请妥善保存数据库密码: $DBPASS${NC}"
log "${YELLOW}使用说明:${NC}"
log "1. 访问 https://$DOMAIN 上传eSIM配置文件"
log "2. 系统会为每个配置文件生成唯一激活码"
log "3. 在设备上输入SM-DP地址: https://$DOMAIN/smdp/"
log "4. 输入激活码下载配置文件"
log "5. 可随时在Web界面删除配置文件"
