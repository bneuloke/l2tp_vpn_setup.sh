#!/bin/bash

# Private 5ber One-Click Deployment Script
# This script will deploy the Private 5ber application on an Ubuntu VPS

# Exit on any error
set -e

# Define variables
DOMAIN="wrxilove.dpdns.org"
IP="98.85.252.221"
PROJECT_DIR="/opt/private-5ber"
DB_PASSWORD=$(openssl rand -base64 32)
SECRET_KEY=$(openssl rand -hex 32)

# Print banner
echo ""
echo "========================================"
echo "   Private 5ber One-Click Deployment   "
echo "========================================"
echo ""
echo "Domain: $DOMAIN"
echo "IP: $IP"
echo "Project Directory: $PROJECT_DIR"
echo ""

# Update system
echo "Updating system packages..."
apt-get update
apt-get upgrade -y

# Install dependencies
echo "Installing dependencies..."
apt-get install -y curl git nginx python3-certbot-nginx

# Install Docker and Docker Compose
echo "Installing Docker and Docker Compose..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker $USER
curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create project directory
echo "Creating project directory..."
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# Create directories for uploads and logs
mkdir -p $PROJECT_DIR/uploads
mkdir -p $PROJECT_DIR/logs

# Create Docker Compose file
echo "Creating Docker Compose file..."
cat > docker-compose.yml <<EOF
version: '3'
services:
  web:
    build: .
    restart: always
    volumes:
      - ./uploads:/app/uploads
      - ./logs:/app/logs
    environment:
      - FLASK_ENV=production
      - SECRET_KEY=$SECRET_KEY
      - DATABASE_URL=postgresql://postgres:$DB_PASSWORD@db:5432/private5ber
    depends_on:
      - db
    expose:
      - 5000

  db:
    image: postgres:13
    restart: always
    environment:
      - POSTGRES_PASSWORD=$DB_PASSWORD
      - POSTGRES_DB=private5ber
    volumes:
      - postgres_data:/var/lib/postgresql/data

  nginx:
    image: nginx:latest
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - web

volumes:
  postgres_data:
EOF

# Create Flask application Dockerfile
echo "Creating Dockerfile for Flask application..."
cat > Dockerfile <<EOF
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]
EOF

# Create requirements.txt
echo "Creating requirements.txt..."
cat > requirements.txt <<EOF
Flask==2.0.1
Flask-SQLAlchemy==2.5.1
psycopg2-binary==2.9.1
gunicorn==20.1.0
python-dotenv==0.19.0
Werkzeug==2.0.1
EOF

# Create Flask application
echo "Creating Flask application..."
cat > app.py <<EOF
import os
from flask import Flask, render_template, request, redirect, url_for, flash, send_from_directory
from flask_sqlalchemy import SQLAlchemy
from werkzeug.utils import secure_filename
from datetime import datetime

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'default-secret-key')
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('DATABASE_URL', 'sqlite:///private5ber.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = 'uploads'
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max file size

db = SQLAlchemy(app)

class EsimProfile(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(255), nullable=False)
    original_filename = db.Column(db.String(255), nullable=False)
    upload_date = db.Column(db.DateTime, default=datetime.utcnow)
    activation_code = db.Column(db.String(255), nullable=True)
    download_url = db.Column(db.String(255), nullable=True)

    def __repr__(self):
        return f'<EsimProfile {self.original_filename}>'

@app.route('/')
def index():
    profiles = EsimProfile.query.all()
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
        original_filename = secure_filename(file.filename)
        file_extension = original_filename.rsplit('.', 1)[1].lower()
        
        # Generate a unique filename to avoid conflicts
        filename = f"{datetime.now().strftime('%Y%m%d%H%M%S')}.{file_extension}"
        
        # Save the file
        file.save(os.path.join(app.config['UPLOAD_FOLDER'], filename))
        
        # Extract activation code and download URL if possible
        activation_code = None
        download_url = None
        
        # For demonstration, we'll just store the file
        # In a real implementation, you would parse the eSIM profile here
        
        # Save to database
        new_profile = EsimProfile(
            filename=filename,
            original_filename=original_filename,
            activation_code=activation_code,
            download_url=download_url
        )
        db.session.add(new_profile)
        db.session.commit()
        
        flash('File successfully uploaded')
        return redirect(url_for('index'))

@app.route('/download/<int:profile_id>')
def download_profile(profile_id):
    profile = EsimProfile.query.get_or_404(profile_id)
    return send_from_directory(app.config['UPLOAD_FOLDER'], profile.filename, as_attachment=True)

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

# Create templates directory and index.html
mkdir -p templates
cat > templates/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Private 5ber</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 1000px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f9f9f9;
            border-radius: 5px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #2c3e50;
            text-align: center;
            margin-bottom: 30px;
        }
        .upload-form {
            background-color: #fff;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 30px;
            box-shadow: 0 0 5px rgba(0,0,0,0.1);
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
            background-color: #f2f2f2;
            font-weight: bold;
        }
        .profiles-table tr:hover {
            background-color: #f5f5f5;
        }
        .btn {
            display: inline-block;
            padding: 8px 15px;
            background-color: #3498db;
            color: white;
            text-decoration: none;
            border-radius: 4px;
            border: none;
            cursor: pointer;
        }
        .btn-danger {
            background-color: #e74c3c;
        }
        .flash {
            padding: 10px;
            margin: 10px 0;
            border-radius: 4px;
        }
        .flash-success {
            background-color: #d4edda;
            color: #155724;
        }
        .flash-error {
            background-color: #f8d7da;
            color: #721c24;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Private 5ber - eSIM Profile Manager</h1>
        
        {% with messages = get_flashed_messages() %}
            {% if messages %}
                {% for message in messages %}
                    <div class="flash flash-success">{{ message }}</div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <div class="upload-form">
            <h2>Upload eSIM Profile</h2>
            <form method="post" enctype="multipart/form-data" action="/upload">
                <input type="file" name="file" required>
                <button type="submit" class="btn">Upload</button>
            </form>
        </div>
        
        <h2>Stored eSIM Profiles</h2>
        {% if profiles %}
            <table class="profiles-table">
                <thead>
                    <tr>
                        <th>Original Filename</th>
                        <th>Upload Date</th>
                        <th>Activation Code</th>
                        <th>Download URL</th>
                        <th>Actions</th>
                    </tr>
                </thead>
                <tbody>
                    {% for profile in profiles %}
                        <tr>
                            <td>{{ profile.original_filename }}</td>
                            <td>{{ profile.upload_date.strftime('%Y-%m-%d %H:%M') }}</td>
                            <td>{{ profile.activation_code or 'N/A' }}</td>
                            <td>{{ profile.download_url or 'N/A' }}</td>
                            <td>
                                <a href="/download/{{ profile.id }}" class="btn">Download</a>
                                <a href="/delete/{{ profile.id }}" class="btn btn-danger" onclick="return confirm('Are you sure you want to delete this profile?')">Delete</a>
                            </td>
                        </tr>
                    {% endfor %}
                </tbody>
            </table>
        {% else %}
            <p>No eSIM profiles stored yet. Upload one using the form above.</p>
        {% endif %}
    </div>
</body>
</html>
EOF

# Create Nginx configuration
echo "Creating Nginx configuration..."
cat > nginx.conf <<EOF
events {
    worker_connections 1024;
}

http {
    upstream web {
        server web:5000;
    }

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

        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
        include /etc/letsencrypt/options-ssl-nginx.conf;
        ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

        location / {
            proxy_pass http://web;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF

# Create directories for Certbot
mkdir -p certbot/conf certbot/www

# Build and start services
echo "Building and starting services..."
docker-compose up -d --build

# Wait for services to start
echo "Waiting for services to start..."
sleep 30

# Request SSL certificate
echo "Requesting SSL certificate..."
docker-compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d $DOMAIN --email admin@$DOMAIN --agree-tos --no-eff-email --force-renewal

# Reload Nginx to apply SSL configuration
echo "Reloading Nginx..."
docker-compose exec nginx nginx -s reload

# Set up cron job for certificate renewal
echo "Setting up cron job for certificate renewal..."
(crontab -l 2>/dev/null; echo "0 3 * * * cd $PROJECT_DIR && docker-compose run --rm certbot renew && docker-compose exec nginx nginx -s reload") | crontab -

# Print completion message
echo ""
echo "========================================"
echo "   Deployment Complete!                "
echo "========================================"
echo ""
echo "Your Private 5ber system is now running at: https://$DOMAIN"
echo ""
echo "To update or manage the application:"
echo " - Navigate to: $PROJECT_DIR"
echo " - Run: docker-compose ps (to check status)"
echo " - Run: docker-compose logs (to view logs)"
echo ""
echo "SSL certificates will auto-renew via cron job."
echo ""
