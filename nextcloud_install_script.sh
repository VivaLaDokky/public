#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

# Defaults
HOSTNAME="localhost"
USERNAME="admin"
PASSWORD="password123"
EMAIL="test@example.com"
STORAGEACCOUNT=""
CONTAINER=""

for i in "$@"
do
    case $i in
        --hostname=*)
        HOSTNAME="${i#*=}" 
        ;;
        --username=*)
        USERNAME="${i#*=}"
        ;;
        --password=*)
        PASSWORD="${i#*=}"
        ;;
        --email=*)
        EMAIL="${i#*=}"
        ;;
        --storageaccount=*)
        STORAGEACCOUNT="${i#*=}"
        ;;  
        --container=*)
        CONTAINER="${i#*=}"
        ;;          
        *)
        ;;
    esac
done

# Install Dependencies
apt-get update && apt-get install -y unzip php8.2 php8.2-cli php8.2-common php8.2-imap php8.2-redis php8.2-snmp php8.2-xml php8.2-zip php8.2-mbstring php8.2-curl php8.2-gd php8.2-mysql apache2 mariadb-server certbot python3-certbot-apache nfs-common

# Secure MySQL and Create the database
DBPASSWORD=$(openssl rand -base64 18)
mysql -e "CREATE DATABASE nextcloud;GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD';FLUSH PRIVILEGES;"

# Mount the file storage
mkdir -p /mnt/files
echo "$STORAGEACCOUNT.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER  /mnt/files    nfs defaults,sec=sys,vers=4,nolock,proto=tcp,nofail    0 0" >> /etc/fstab 
mount /mnt/files

# Download Nextcloud
cd /var/www/html
wget https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip
chown -R root:root nextcloud
cd nextcloud

# Install Nextcloud
php occ maintenance:install --database "mysql" --database-name "nextcloud" --database-user "nextcloud" --database-pass "$DBPASSWORD" --admin-user "$USERNAME" --admin-pass "$PASSWORD" --data-dir /mnt/files
sed -i "s/0 => 'localhost',/0 => '$HOSTNAME',/g" ./config/config.php
sed -i "s/  'overwrite.cli.url' => 'https:\/\/localhost',/  'overwrite.cli.url' => 'http:\/\/$HOSTNAME',/g" ./config/config.php

cd ..
chown -R www-data:www-data nextcloud
chown -R www-data:www-data /mnt/files

# Configure Apache
tee /etc/apache2/sites-available/nextcloud.conf > /dev/null << EOF
<VirtualHost *:80>
ServerName $HOSTNAME
DocumentRoot /var/www/html/nextcloud

<Directory /var/www/html/nextcloud/>
 Require all granted
 Options FollowSymlinks MultiViews
 AllowOverride All
 <IfModule mod_dav.c>
 Dav off
 </IfModule>
</Directory>

ErrorLog /var/log/apache2/$HOSTNAME.error_log
CustomLog /var/log/apache2/$HOSTNAME.access_log common
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2enmod rewrite

# Obtain a Certificate from Let's Encrypt
certbot --apache --agree-tos -m $EMAIL -d $HOSTNAME -n
systemctl restart apache2
