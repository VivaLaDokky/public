# Add backup/restore functionality for VM recreation resilience
echo_status "Setting up backup configuration"

# Create backup directory in the NFS mount
BACKUP_DIR="$NFS_MOUNT_PATH/nextcloud-backups"
mkdir -p $BACKUP_DIR

# Set up a script to perform regular backups of the database and config
cat > /usr/local/bin/nextcloud-backup.sh << EOF
#!/bin/bash
# Nextcloud backup script
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$BACKUP_DIR"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
DB_NAME="$DB_NAME"

# Backup database
mysqldump -u \$DB_USER -p\$DB_PASS \$DB_NAME > \$BACKUP_DIR/nextcloud-db-\$TIMESTAMP.sql

# Backup configuration
cp /var/www/nextcloud/config/config.php \$BACKUP_DIR/config-\$TIMESTAMP.php

# Keep only the 5 most recent backups
ls -t \$BACKUP_DIR/nextcloud-db-* | tail -n +6 | xargs -r rm
ls -t \$BACKUP_DIR/config-* | tail -n +6 | xargs -r rm

echo "Nextcloud backup completed: \$(date)"
EOF

chmod +x /usr/local/bin/nextcloud-backup.sh

# Set up a daily cron job for backups
echo "0 2 * * * root /usr/local/bin/nextcloud-backup.sh > /var/log/nextcloud-backup.log 2>&1" > /etc/cron.d/nextcloud-backup

# Create a file in the NFS mount to help future installations detect this is a remount
cat > "$NFS_MOUNT_PATH/nextcloud-installation-info.txt" << EOF
# Nextcloud Installation Information
Installation Date: $(date)
Hostname: $HOSTNAME
Storage Account: $STORAGEACCOUNT
Container: $CONTAINER
Database Name: $DB_NAME
Database User: $DB_USER
EOF

# Create a restore script for future use
cat > /usr/local/bin/nextcloud-restore.sh << EOF
#!/bin/bash
# Nextcloud restore script for VM recreation
BACKUP_DIR="$BACKUP_DIR"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
DB_NAME="$DB_NAME"

# Find the most recent backup
LATEST_DB=\$(ls -t \$BACKUP_DIR/nextcloud-db-* | head -n 1)
LATEST_CONFIG=\$(ls -t \$BACKUP_DIR/config-* | head -n 1)

if [ -z "\$LATEST_DB" ] || [ -z "\$LATEST_CONFIG" ]; then
    echo "No backups found!"
    exit 1
fi

echo "Restoring from \$LATEST_DB and \$LATEST_CONFIG"

# Restore database
mysql -u \$DB_USER -p\$DB_PASS \$DB_NAME < \$LATEST_DB

# Restore configuration
cp \$LATEST_CONFIG /var/www/nextcloud/config/config.php
chown www-data:www-data /var/www/nextcloud/config/config.php

echo "Restoration completed at \$(date)"
echo "Please run 'sudo -u www-data php /var/www/nextcloud/occ maintenance:data-fingerprint' to refresh file caches"
EOF

chmod +x /usr/local/bin/nextcloud-restore.sh

# Run initial backup
/usr/local/bin/nextcloud-backup.sh#!/bin/bash

# Nextcloud Installation Script for Ubuntu with Azure Blob NFS Mount
# This script installs Nextcloud on an Ubuntu VM and configures it to use Azure Blob Storage via NFS

# Exit on error
set -e

# Function to display usage instructions
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -s, --storage-account  Azure Storage Account name (required)"
    echo "  -c, --container        Azure Container name (required)"
    echo "  -h, --hostname         Server hostname (default: $(hostname -f))"
    echo "  -d, --domain           Domain name for SSL certificate (optional)"
    echo "  -a, --admin-user       Nextcloud admin username (default: admin)"
    echo "  -e, --email            Email address for SSL certificate notifications (required with domain)"
    echo "  --help                 Display this help message and exit"
    exit 1
}

# Initialize variables with default values
STORAGEACCOUNT=""
CONTAINER=""
HOSTNAME=$(hostname -f)
DOMAIN=""
EMAIL=""
ADMIN_USER="admin"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--storage-account)
            STORAGEACCOUNT="$2"
            shift 2
            ;;
        -c|--container)
            CONTAINER="$2"
            shift 2
            ;;
        -h|--hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -a|--admin-user)
            ADMIN_USER="$2"
            shift 2
            ;;
        -e|--email)
            EMAIL="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$STORAGEACCOUNT" ] || [ -z "$CONTAINER" ]; then
    echo "Error: Storage account and container parameters are required"
    usage
fi

# If domain is provided, email is required for Certbot
if [ ! -z "$DOMAIN" ] && [ -z "$EMAIL" ]; then
    echo "Error: Email address is required when using a domain name for SSL"
    usage
fi

# Other configuration variables
NFS_MOUNT_PATH="/mnt/azure-blob"
NEXTCLOUD_DATA_DIR="/var/www/nextcloud/data"

# Database configuration
DB_NAME="nextcloud"
DB_USER="nextcloud_user"
DB_PASS="$(openssl rand -base64 12)"  # Generate a random password
ADMIN_PASS="$(openssl rand -base64 12)"  # Generate a random password

# Determine Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs)
echo "Ubuntu version: $UBUNTU_VERSION"

# Function to display status messages
function echo_status() {
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

# Update system
echo_status "Updating system packages"
apt update && apt upgrade -y

# Install necessary packages
echo_status "Installing required packages"
apt install -y apache2 mariadb-server libapache2-mod-php php-gd php-json php-mysql \
    php-curl php-mbstring php-intl php-imagick php-xml php-zip php-bz2 \
    php-bcmath php-gmp unzip nfs-common

# Check if the system needs a reboot (based on your error log)
if [ -f /var/run/reboot-required ]; then
    echo_status "WARNING: System requires a reboot"
    echo "The system indicates that a reboot is required, possibly due to kernel updates."
    echo "It's recommended to reboot before continuing with Nextcloud installation."
    echo ""
    read -p "Continue anyway? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation aborted. Please reboot and run the script again."
        exit 1
    fi
fi

# Install Certbot if domain is provided
if [ ! -z "$DOMAIN" ]; then
    echo_status "Installing Certbot for SSL"
    apt install -y certbot python3-certbot-apache || {
        echo "Failed to install certbot. Continuing without SSL..."
        DOMAIN=""
    }
fi

# Configure Apache
echo_status "Configuring Apache"
cat > /etc/apache2/sites-available/nextcloud.conf << EOF
<VirtualHost *:80>
    ServerName ${DOMAIN:-$HOSTNAME}
    DocumentRoot /var/www/nextcloud/
    
    <Directory /var/www/nextcloud/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
        
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
        
        SetEnv HOME /var/www/nextcloud
        SetEnv HTTP_HOME /var/www/nextcloud
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2enmod rewrite headers env dir mime

# Configure MariaDB
echo_status "Configuring MariaDB"
systemctl start mariadb
systemctl enable mariadb

# Secure MariaDB installation - compatible with newer MariaDB versions
echo_status "Securing MariaDB installation"

# Set root password - using more compatible approach
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASS';" || {
    # Fallback for older MariaDB versions
    echo "Attempting alternative method for setting root password..."
    mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$DB_PASS');" || {
        # Another fallback method
        echo "Using mysqladmin to set root password..."
        mysqladmin -u root password "$DB_PASS"
    }
}

# Using root password for subsequent commands
MYSQL_CMD="mysql -u root -p$DB_PASS"

# Secure the database
$MYSQL_CMD -e "DELETE FROM mysql.global_priv WHERE User='';" || $MYSQL_CMD -e "DELETE FROM mysql.user WHERE User='';"
$MYSQL_CMD -e "DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" || $MYSQL_CMD -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
$MYSQL_CMD -e "DROP DATABASE IF EXISTS test;"
$MYSQL_CMD -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
$MYSQL_CMD -e "FLUSH PRIVILEGES;"

# Create database and user for Nextcloud
echo_status "Creating Nextcloud database and user"
$MYSQL_CMD -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
$MYSQL_CMD -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
$MYSQL_CMD -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
$MYSQL_CMD -e "FLUSH PRIVILEGES;"

# Set up the NFS mount for Azure Blob Storage
echo_status "Setting up NFS mount for Azure Blob Storage"
mkdir -p $NFS_MOUNT_PATH

# Add the NFS mount to fstab if not already there
if ! grep -q "$STORAGEACCOUNT.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER" /etc/fstab; then
    echo "$STORAGEACCOUNT.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER $NFS_MOUNT_PATH nfs vers=4,minorversion=1,sec=sys,rw 0 0" >> /etc/fstab
fi

# Mount the NFS share
mount $NFS_MOUNT_PATH || {
    echo_status "WARNING: Failed to mount NFS share"
    echo "Attempting to mount with different NFS version..."
    # Try alternative NFS options
    umount $NFS_MOUNT_PATH 2>/dev/null || true
    mount -t nfs -o vers=3 "$STORAGEACCOUNT.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER" $NFS_MOUNT_PATH || {
        echo_status "ERROR: Failed to mount NFS share"
        echo "Please check your Azure Storage Account configuration and ensure NFS access is enabled."
        exit 1
    }
}

# Download and install Nextcloud
echo_status "Downloading and installing Nextcloud"
cd /tmp
wget https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip -d /var/www/
chown -R www-data:www-data /var/www/nextcloud

# Create symlink for Nextcloud data directory
echo_status "Configuring Nextcloud data directory on NFS mount"
mkdir -p $NFS_MOUNT_PATH/nextcloud-data
chown -R www-data:www-data $NFS_MOUNT_PATH/nextcloud-data

# Configure PHP
echo_status "Configuring PHP"
for php_ver in /etc/php/*/apache2/php.ini; do
    sed -i 's/memory_limit = .*/memory_limit = 512M/' $php_ver
    sed -i 's/upload_max_filesize = .*/upload_max_filesize = 10G/' $php_ver
    sed -i 's/post_max_size = .*/post_max_size = 10G/' $php_ver
    sed -i 's/max_execution_time = .*/max_execution_time = 300/' $php_ver
    sed -i 's/;opcache.enable=.*/opcache.enable=1/' $php_ver
    sed -i 's/;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=8/' $php_ver
    sed -i 's/;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' $php_ver
    sed -i 's/;opcache.memory_consumption=.*/opcache.memory_consumption=128/' $php_ver
    sed -i 's/;opcache.save_comments=.*/opcache.save_comments=1/' $php_ver
    sed -i 's/;opcache.revalidate_freq=.*/opcache.revalidate_freq=1/' $php_ver
done

# Restart Apache
echo_status "Restarting Apache"
systemctl restart apache2

# Install Nextcloud via console
echo_status "Completing Nextcloud installation"
cd /var/www/nextcloud
sudo -u www-data php occ maintenance:install \
    --database "mysql" \
    --database-name "$DB_NAME" \
    --database-user "$DB_USER" \
    --database-pass "$DB_PASS" \
    --admin-user "$ADMIN_USER" \
    --admin-pass "$ADMIN_PASS" \
    --data-dir "$NFS_MOUNT_PATH/nextcloud-data"

# Configure trusted domains
sudo -u www-data php occ config:system:set trusted_domains 1 --value="$HOSTNAME"
if [ ! -z "$DOMAIN" ]; then
    sudo -u www-data php occ config:system:set trusted_domains 2 --value="$DOMAIN"
fi
IP_ADDRESS=$(hostname -I | awk '{print $1}')
sudo -u www-data php occ config:system:set trusted_domains 3 --value="$IP_ADDRESS"

# Configure SSL with Certbot if domain is provided
if [ ! -z "$DOMAIN" ]; then
    echo_status "Configuring SSL with Certbot"
    certbot --apache -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" --redirect || {
        echo_status "WARNING: SSL configuration failed"
        echo "Continuing with HTTP only configuration..."
        # Reset domain to indicate SSL failed
        DOMAIN=""
    }
    
    if [ ! -z "$DOMAIN" ]; then
        # Force HTTPS in Nextcloud
        sudo -u www-data php occ config:system:set overwriteprotocol --value="https"
        
        # Enable HTTP Strict Transport Security
        sudo -u www-data php occ config:system:set hsts --value="true"
        sudo -u www-data php occ config:system:set hstsMaxAge --value="31536000"
        sudo -u www-data php occ config:system:set hstsIncludeSubdomains --value="true"
        sudo -u www-data php occ config:system:set hstsPreload --value="true"
    fi
fi

# Display completion message
echo_status "Nextcloud Installation Completed!"
echo "======================================================"
echo "Nextcloud has been successfully installed!"

if [ ! -z "$DOMAIN" ]; then
    echo "Web interface: https://$DOMAIN/"
else
    echo "Web interface: http://$HOSTNAME/"
    echo "              http://$IP_ADDRESS/"
fi

echo "Admin user: $ADMIN_USER"
echo "Admin password: $ADMIN_PASS"
echo "Database user: $DB_USER"
echo "Database password: $DB_PASS"
echo ""
echo "Please save these credentials in a secure location."
echo "For security reasons, consider changing the admin password immediately."
echo "======================================================"

# Save credentials to a file in the user's home directory
echo "# Nextcloud Installation Credentials - $(date)" > ~/nextcloud-credentials.txt
if [ ! -z "$DOMAIN" ]; then
    echo "Nextcloud URL: https://$DOMAIN/" >> ~/nextcloud-credentials.txt
else
    echo "Nextcloud URL: http://$HOSTNAME/" >> ~/nextcloud-credentials.txt
    echo "              http://$IP_ADDRESS/" >> ~/nextcloud-credentials.txt
fi
echo "Admin username: $ADMIN_USER" >> ~/nextcloud-credentials.txt
echo "Admin password: $ADMIN_PASS" >> ~/nextcloud-credentials.txt
echo "Database name: $DB_NAME" >> ~/nextcloud-credentials.txt
echo "Database user: $DB_USER" >> ~/nextcloud-credentials.txt
echo "Database password: $DB_PASS" >> ~/nextcloud-credentials.txt
echo "" >> ~/nextcloud-credentials.txt
echo "Azure Storage Account: $STORAGEACCOUNT" >> ~/nextcloud-credentials.txt
echo "Azure Container: $CONTAINER" >> ~/nextcloud-credentials.txt
echo "NFS Mount Path: $NFS_MOUNT_PATH" >> ~/nextcloud-credentials.txt
echo "" >> ~/nextcloud-credentials.txt
echo "Credentials saved to ~/nextcloud-credentials.txt"

echo "Installation complete!"
