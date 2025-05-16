
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
PHP_VERSION="8.1"  # Default to PHP 8.1 which is available in Ubuntu 22.04

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
        --php-version=*)
            PHP_VERSION="${i#*=}"
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

# Install necessary tools first
echo "Installing essential tools..."
apt-get install -y wget curl unzip software-properties-common apt-transport-https gnupg lsb-release ca-certificates

# Add PHP repository for more recent PHP versions if needed
if [ "$PHP_VERSION" != "8.1" ]; then
    echo "Adding PHP repository for PHP $PHP_VERSION..."
    add-apt-repository -y ppa:ondrej/php
    apt-get update
fi

# Install Redis for improved caching
echo "Installing Redis..."
apt-get install -y redis-server

# Install Apache and MariaDB first (these are in default repos)
echo "Installing Apache and MariaDB..."
apt-get install -y apache2 mariadb-server
# Install PHP and required extensions
echo "Installing PHP and extensions..."
apt-get install -y php${PHP_VERSION} libapache2-mod-php${PHP_VERSION} \
    php${PHP_VERSION}-cli php${PHP_VERSION}-common php${PHP_VERSION}-imap \
    php${PHP_VERSION}-redis php${PHP_VERSION}-xml php${PHP_VERSION}-zip \
    php${PHP_VERSION}-mbstring php${PHP_VERSION}-curl php${PHP_VERSION}-gd \
    php${PHP_VERSION}-mysql php${PHP_VERSION}-intl php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-gmp php${PHP_VERSION}-imagick php${PHP_VERSION}-bz2 \
    php${PHP_VERSION}-fpm php${PHP_VERSION}-ldap php${PHP_VERSION}-apcu

# Install other required packages
echo "Installing additional dependencies..."
apt-get install -y certbot python3-certbot-apache ssl-cert

# Check if NFS tools are needed
if [ -n "$STORAGEACCOUNT" ] && [ -n "$CONTAINER" ]; then
    apt-get install -y nfs-common
fi

# Secure MariaDB installation
echo "Securing MariaDB..."
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)

# Check if mysqladmin exists
if command -v mysqladmin &> /dev/null; then
    mysqladmin --user=root password "$MYSQL_ROOT_PASSWORD"
else
    echo "mysqladmin not found, setting root password through SQL"
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
fi

# Create database and user for Nextcloud
echo "Creating database for Nextcloud..."
DBPASSWORD=$(openssl rand -base64 32)

# Use either root password or without password based on MySQL installation state
if mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES" &> /dev/null; then
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
EOF
else
    # Try without password (fresh installation might not have password set yet)
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

# Configure file storage mount with better error handling
echo "Setting up file storage..."
mkdir -p /mnt/files

if [ -n "$STORAGEACCOUNT" ] && [ -n "$CONTAINER" ]; then
    echo "Configuring NFS mount for Azure storage..."
    
    # Check if NFS client is installed
    if ! command -v mount.nfs &> /dev/null; then
        echo "NFS client not found, installing..."
        apt-get install -y nfs-common
    fi
    
    echo "$STORAGEACCOUNT.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER /mnt/files nfs defaults,sec=sys,vers=3,nolock,proto=tcp,nofail,_netdev 0 0" >> /etc/fstab
    
    # Attempt to mount and verify
    if ! mount /mnt/files 2>/dev/null; then
        echo "Warning: Failed to mount NFS share. Check your storage account and container names."
        # Continue with local storage as fallback
        mkdir -p /var/nextcloud-data
        chown www-data:www-data /var/nextcloud-data
        ln -sf /var/nextcloud-data /mnt/files
    fi
else
    echo "No storage account specified, using local storage..."
    mkdir -p /var/nextcloud-data
    chown www-data:www-data /var/nextcloud-data
    ln -sf /var/nextcloud-data /mnt/files
fi

# Download and extract Nextcloud
echo "Downloading Nextcloud $NEXTCLOUD_VERSION..."
mkdir -p /var/www/html
cd /var/www/html

# Ensure wget is installed
if ! command -v wget &> /dev/null; then
    apt-get install -y wget
fi

# Ensure unzip is installed
if ! command -v unzip &> /dev/null; then
    apt-get install -y unzip
fi

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

# Ensure PHP CLI is available
if ! command -v php &> /dev/null; then
    echo "PHP CLI not found! Checking if it's installed with a different name..."
    PHP_CMD="php${PHP_VERSION}"
    if ! command -v $PHP_CMD &> /dev/null; then
        echo "Error: PHP CLI not available. Cannot continue installation."
        exit 1
    fi
else
    PHP_CMD="php"
fi

sudo -u www-data $PHP_CMD occ maintenance:install \
    --database "mysql" \
    --database-name "nextcloud" \
    --database-user "nextcloud" \
    --database-pass "$DBPASSWORD" \
    --admin-user "$USERNAME" \
    --admin-pass "$PASSWORD" \
    --data-dir "/mnt/files"

# Configure trusted domains
echo "Configuring trusted domains..."
sudo -u www-data $PHP_CMD occ config:system:set trusted_domains 0 --value="localhost"
sudo -u www-data $PHP_CMD occ config:system:set trusted_domains 1 --value="$HOSTNAME"

# Enable recommended PHP modules
echo "Enabling recommended apps and configurations..."
sudo -u www-data $PHP_CMD occ app:enable admin_audit
sudo -u www-data $PHP_CMD occ app:enable encryption
sudo -u www-data $PHP_CMD occ background:cron

# Configure Redis caching
echo "Configuring Redis caching..."
sudo -u www-data $PHP_CMD occ config:system:set memcache.local --value='\OC\Memcache\APCu'
sudo -u www-data $PHP_CMD occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
sudo -u www-data $PHP_CMD occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
sudo -u www-data $PHP_CMD occ config:system:set redis host --value='localhost'
sudo -u www-data $PHP_CMD occ config:system:set redis port --value=6379

# Setup cron job for background tasks
echo "Setting up cron job..."
echo "*/5 * * * * www-data php -f /var/www/html/nextcloud/cron.php" > /etc/cron.d/nextcloud

# Configure Apache
echo "Configuring Apache..."
mkdir -p /etc/apache2/sites-available

# Check if Apache is properly installed
if [ ! -d "/etc/apache2/sites-available" ]; then
    echo "Apache configuration directory not found, installing Apache..."
    apt-get install -y apache2
fi

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

    ErrorLog \${APACHE_LOG_DIR}/$HOSTNAME.error.log
    CustomLog \${APACHE_LOG_DIR}/$HOSTNAME.access.log combined
</VirtualHost>
EOF

# Check if Apache command line tools are available
if command -v a2enmod &> /dev/null; then
    # Enable required Apache modules
    a2enmod rewrite headers env dir mime ssl
    a2ensite nextcloud.conf
    a2dissite 000-default.conf
else
    echo "Apache command line tools not found, but we've created the config file."
    echo "Please manually enable the site when Apache is properly installed."
fi

# Setup SSL with Let's Encrypt if hostname is not localhost
if [ "$HOSTNAME" != "localhost" ]; then
    echo "Setting up SSL certificate with Let's Encrypt..."
    
    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        echo "Certbot not found, installing..."
        apt-get install -y certbot python3-certbot-apache
    fi
    
    # Only run if Apache is properly installed
    if command -v a2enmod &> /dev/null; then
        certbot --apache -d $HOSTNAME --agree-tos -m $EMAIL --non-interactive --redirect
    else
        echo "Apache not properly installed, skipping SSL setup"
    fi
else
    echo "Skipping Let's Encrypt as hostname is localhost"
fi

# Apply Nextcloud recommended PHP settings
echo "Optimizing PHP settings..."
PHP_INI_DIR="/etc/php/${PHP_VERSION}/apache2/conf.d"
PHP_FPM_INI_DIR="/etc/php/${PHP_VERSION}/fpm/conf.d"

# Create directories if they don't exist
mkdir -p $PHP_INI_DIR
mkdir -p $PHP_FPM_INI_DIR

cat > $PHP_INI_DIR/99-nextcloud.ini << EOF
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
cp $PHP_INI_DIR/99-nextcloud.ini $PHP_FPM_INI_DIR/99-nextcloud.ini

# Restart services
echo "Restarting services..."

# Only restart services that actually exist
systemctl restart redis-server || echo "Failed to restart Redis"

if systemctl list-unit-files | grep -q mariadb.service; then
    systemctl restart mariadb || echo "Failed to restart MariaDB"
fi

if systemctl list-unit-files | grep -q mysql.service; then
    systemctl restart mysql || echo "Failed to restart MySQL"
fi

if systemctl list-unit-files | grep -q "php${PHP_VERSION}-fpm.service"; then
    systemctl restart php${PHP_VERSION}-fpm || echo "Failed to restart PHP-FPM"
fi

if systemctl list-unit-files | grep -q apache2.service; then
    systemctl restart apache2 || echo "Failed to restart Apache"
fi

# Final optimization steps
echo "Performing final optimizations..."
cd /var/www/html/nextcloud
if command -v $PHP_CMD &> /dev/null; then
    sudo -u www-data $PHP_CMD occ db:add-missing-indices || echo "Failed to add missing indices"
    sudo -u www-data $PHP_CMD occ db:convert-filecache-bigint || echo "Failed to convert filecache to bigint"
fi

echo "****************************************************************"
echo "Nextcloud installation complete!"
echo "You can access your Nextcloud instance at: https://$HOSTNAME"
echo "Admin username: $USERNAME"
echo "Database password (save this): $DBPASSWORD"
echo "MySQL root password (save this): $MYSQL_ROOT_PASSWORD"
echo "****************************************************************"
