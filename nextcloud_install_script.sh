#!/bin/bash

# Set noninteractive frontend for automated installation
export DEBIAN_FRONTEND=noninteractive

# Default configuration values
HOSTNAME="localhost"
USERNAME="admin"
PASSWORD="password123"
EMAIL="test@example.com"
STORAGEACCOUNT=""
CONTAINER=""
NEXTCLOUD_VERSION="28.0.3"  # Latest stable as of May 2025

# Parse command line arguments
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
        --nextcloud-version=*)
            NEXTCLOUD_VERSION="${i#*=}"
            ;;
        *)
            # Unknown option
            ;;
    esac
done

echo "Starting Nextcloud installation process..."
echo "Hostname: $HOSTNAME"

# Update system packages
echo "Updating system packages..."
apt-get update
apt-get upgrade -y

# Install Redis for improved caching
echo "Installing Redis..."
apt-get install -y redis-server

# Install PHP and required extensions
# Using PHP 8.2 which is well-supported by current Nextcloud versions
echo "Installing PHP and extensions..."
apt-get install -y php8.2 php8.2-cli php8.2-common php8.2-imap php8.2-redis \
    php8.2-snmp php8.2-xml php8.2-zip php8.2-mbstring php8.2-curl php8.2-gd \
    php8.2-mysql php8.2-intl php8.2-bcmath php8.2-gmp php8.2-imagick php8.2-fpm \
    php8.2-bz2 php8.2-apcu php8.2-ldap

# Install other required packages
echo "Installing additional dependencies..."
apt-get install -y apache2 mariadb-server certbot python3-certbot-apache \
    unzip nfs-common libapache2-mod-php8.2 ssl-cert

# Secure MariaDB installation
echo "Securing MariaDB..."
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
mysqladmin --user=root password "$MYSQL_ROOT_PASSWORD"

# Create database and user for Nextcloud
echo "Creating database for Nextcloud..."
DBPASSWORD=$(openssl rand -base64 32)
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
EOF

# Configure file storage mount with better error handling
echo "Setting up file storage..."
mkdir -p /mnt/files

if [ -n "$STORAGEACCOUNT" ] && [ -n "$CONTAINER" ]; then
    echo "Configuring NFS mount for Azure storage..."
    echo "$STORAGEACCOUNT.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER /mnt/files nfs defaults,sec=sys,vers=3,nolock,proto=tcp,nofail,_netdev 0 0" >> /etc/fstab
    
    # Attempt to mount and verify
    mount /mnt/files
    if [ $? -ne 0 ]; then
        echo "Warning: Failed to mount NFS share. Check your storage account and container names."
        # Continue with local storage as fallback
        mkdir -p /var/nextcloud-data
        chown www-data:www-data /var/nextcloud-data
        ln -s /var/nextcloud-data /mnt/files
    fi
else
    echo "No storage account specified, using local storage..."
    mkdir -p /var/nextcloud-data
    chown www-data:www-data /var/nextcloud-data
    ln -s /var/nextcloud-data /mnt/files
fi

# Download and extract Nextcloud
echo "Downloading Nextcloud $NEXTCLOUD_VERSION..."
cd /var/www/html
wget -q https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip
unzip -q nextcloud-${NEXTCLOUD_VERSION}.zip
rm nextcloud-${NEXTCLOUD_VERSION}.zip

# Set proper ownership and permissions
echo "Setting permissions..."
chown -R www-data:www-data nextcloud
chmod -R 755 nextcloud

# Install Nextcloud
echo "Installing Nextcloud..."
cd nextcloud
sudo -u www-data php occ maintenance:install \
    --database "mysql" \
    --database-name "nextcloud" \
    --database-user "nextcloud" \
    --database-pass "$DBPASSWORD" \
    --admin-user "$USERNAME" \
    --admin-pass "$PASSWORD" \
    --data-dir "/mnt/files"

# Configure trusted domains
echo "Configuring trusted domains..."
sudo -u www-data php occ config:system:set trusted_domains 0 --value="localhost"
sudo -u www-data php occ config:system:set trusted_domains 1 --value="$HOSTNAME"

# Enable recommended PHP modules
echo "Enabling recommended apps and configurations..."
sudo -u www-data php occ app:enable admin_audit
sudo -u www-data php occ app:enable encryption
sudo -u www-data php occ background:cron

# Configure Redis caching
echo "Configuring Redis caching..."
sudo -u www-data php occ config:system:set memcache.local --value='\OC\Memcache\APCu'
sudo -u www-data php occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
sudo -u www-data php occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
sudo -u www-data php occ config:system:set redis host --value='localhost'
sudo -u www-data php occ config:system:set redis port --value=6379

# Setup cron job for background tasks
echo "Setting up cron job..."
echo "*/5 * * * * www-data php -f /var/www/html/nextcloud/cron.php" > /etc/cron.d/nextcloud

# Configure Apache
echo "Configuring Apache..."
cat > /etc/apache2/sites-available/nextcloud.conf << EOF
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

        # Modern security headers
        <IfModule mod_headers.c>
            Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
            Header always set X-Content-Type-Options "nosniff"
            Header always set X-Frame-Options "SAMEORIGIN"
            Header always set X-XSS-Protection "1; mode=block"
            Header always set Referrer-Policy "strict-origin-when-cross-origin"
        </IfModule>
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/$HOSTNAME.error.log
    CustomLog ${APACHE_LOG_DIR}/$HOSTNAME.access.log combined
</VirtualHost>
EOF

# Enable required Apache modules
a2enmod rewrite headers env dir mime ssl
a2ensite nextcloud.conf
a2dissite 000-default.conf

# Setup SSL with Let's Encrypt if hostname is not localhost
if [ "$HOSTNAME" != "localhost" ]; then
    echo "Setting up SSL certificate with Let's Encrypt..."
    certbot --apache -d $HOSTNAME --agree-tos -m $EMAIL --non-interactive --redirect
else
    echo "Skipping Let's Encrypt as hostname is localhost"
fi

# Apply Nextcloud recommended PHP settings
echo "Optimizing PHP settings..."
cat > /etc/php/8.2/apache2/conf.d/99-nextcloud.ini << EOF
memory_limit = 512M
upload_max_filesize = 10G
post_max_size = 10G
max_execution_time = 300
max_input_time = 300
date.timezone = UTC
opcache.enable = 1
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 1
EOF

# Copy settings to PHP-FPM config as well
cp /etc/php/8.2/apache2/conf.d/99-nextcloud.ini /etc/php/8.2/fpm/conf.d/99-nextcloud.ini

# Restart services
echo "Restarting services..."
systemctl restart redis-server
systemctl restart mariadb
systemctl restart php8.2-fpm
systemctl restart apache2

# Final optimization steps
echo "Performing final optimizations..."
sudo -u www-data php /var/www/html/nextcloud/occ db:add-missing-indices
sudo -u www-data php /var/www/html/nextcloud/occ db:convert-filecache-bigint

echo "****************************************************************"
echo "Nextcloud installation complete!"
echo "You can access your Nextcloud instance at: https://$HOSTNAME"
echo "Admin username: $USERNAME"
echo "Database password (save this): $DBPASSWORD"
echo "MySQL root password (save this): $MYSQL_ROOT_PASSWORD"
echo "****************************************************************"
