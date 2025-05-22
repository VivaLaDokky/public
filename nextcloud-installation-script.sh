#!/bin/bash

# This script automates the setup of a Nextcloud server on a Debian-based system.
# It installs necessary dependencies, configures the database, mounts file storage,
# installs Nextcloud, configures Apache, and sets up SSL with Let's Encrypt.

export DEBIAN_FRONTEND=noninteractive

# --- Configuration Variables ---
# These variables can be overridden by command-line arguments.
HOSTNAME="localhost" # Internal hostname of the server
DNSNAME=""           # Publicly accessible FQDN (e.g., nextcloud.example.com)
USERNAME="admin"
PASSWORD="password123"
EMAIL="test@example.com" # Required for Let's Encrypt
STORAGEACCOUNT=""    # Azure Storage Account Name
CONTAINER=""         # Azure Blob Container Name

# --- Command-line Argument Parsing ---
# This loop processes command-line arguments to override default settings.
for i in "$@"; do # Loop through all arguments
	case $i in
		--hostname=*)
		HOSTNAME="${i#*=}" # Assign value after '=' to HOSTNAME
		;;
		--dnsname=*)
		DNSNAME="${i#*=}"  # Assign value after '=' to DNSNAME
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
		# Unknown option
		echo "Warning: Unknown option $i"
		;;
	esac
done

# Set DNSNAME default if not provided by argument
if [ -z "$DNSNAME" ]; then
    echo "INFO: --dnsname argument not provided. Defaulting DNSNAME to the value of HOSTNAME ('$HOSTNAME')."
    DNSNAME="$HOSTNAME"
fi

echo "--- Starting Server Setup ---"
echo "Server Hostname (local): $HOSTNAME"
echo "Public DNS Name (for access & SSL): $DNSNAME"
echo "Admin Username: $USERNAME"
echo "Admin Email: $EMAIL"

if [ -n "$STORAGEACCOUNT" ] && [ -n "$CONTAINER" ]; then
    echo "Azure Storage Account: $STORAGEACCOUNT"
    echo "Azure Container: $CONTAINER"
else
    echo "INFO: Azure Storage Account or Container not specified. NFS mount for data directory will be skipped or use local storage if /mnt/files is pre-configured."
fi

# --- Install Dependencies ---
sudo apt update
sudo apt install -y software-properties-common lsb-release ca-certificates apt-transport-https
sudo add-apt-repository -y ppa:ondrej/php
echo "--- Updating package lists and upgrading existing packages ---"
apt-get update
apt-get upgrade -y

echo "--- Installing PHP 8.2 and other required packages ---"
# Updated to PHP 8.2 and its corresponding modules
apt-get install -y \
    php8.2 php8.2-cli php8.2-common php8.2-imap php8.2-redis php8.2-snmp \
    php8.2-xml php8.2-zip php8.2-mbstring php8.2-curl php8.2-gd php8.2-mysql \
    apache2 mariadb-server certbot nfs-common python3-certbot-apache unzip

# --- Raise PHP memory limit to 1024M ---
PHP_INI="/etc/php/8.2/apache2/php.ini"

if [ -f "$PHP_INI" ]; then
  echo "--- Setting PHP memory limit to 1024M in $PHP_INI ---"
  sed -i 's/^memory_limit\s*=.*/memory_limit = 1024M/' "$PHP_INI"
else
  echo "WARNING: PHP config file $PHP_INI not found. Memory limit not updated."
fi

# --- Create the database and user for Nextcloud ---
echo "--- Configuring MariaDB for Nextcloud ---"
DBPASSWORD=$(openssl rand -base64 14) # Generate a random password for the database user
mysql -e "CREATE DATABASE IF NOT EXISTS nextcloud;" # Create database if it doesn't exist
mysql -e "GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD';"
mysql -e "FLUSH PRIVILEGES;"
echo "MariaDB configured and Nextcloud database user created."

# --- Mount the file storage (Azure Files via NFS) ---
# This section is specific to using Azure Files.
# Ensure your Azure Storage Account is configured for NFS v3.
if [ -n "$STORAGEACCOUNT" ] && [ -n "$CONTAINER" ]; then
    echo "--- Mounting Azure File Storage via NFS ---"
    mkdir -p /mnt/files
    # Check if the mount point is already in fstab to avoid duplicates
    if ! grep -q "$STORAGEACCOUNT.privatelink.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER" /etc/fstab; then
        # Using single spaces for fstab entry clarity
        echo "$STORAGEACCOUNT.privatelink.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER /mnt/files nfs defaults,sec=sys,vers=3,nolock,proto=tcp,nofail 0 0" >> /etc/fstab
        echo "Added NFS mount to /etc/fstab."
    else
        echo "NFS mount already exists in /etc/fstab."
    fi
    mount /mnt/files # Attempt to mount
    if mountpoint -q /mnt/files; then
        echo "File storage mounted successfully at /mnt/files."
    else
        echo "ERROR: File storage mount failed. Please check NFS server, network, credentials, and fstab entry."
        # Optionally, exit here if the mount is critical
        # exit 1
    fi
else
    echo "INFO: Skipping NFS mount as STORAGEACCOUNT or CONTAINER is not set. Ensure /mnt/files is prepared manually if needed for data."
    # If not using Azure Files, ensure /mnt/files exists and has correct permissions,
    # or change --data-dir in the Nextcloud installation command.
    mkdir -p /mnt/files # Create it anyway, might be a local directory
fi


# --- Download and Install Nextcloud ---
echo "--- Downloading and Installing Nextcloud ---"
NEXTCLOUD_VERSION="nextcloud-31.0.5" # Updated Nextcloud version
NEXTCLOUD_ZIP="${NEXTCLOUD_VERSION}.zip"
NEXTCLOUD_DOWNLOAD_URL="https://download.nextcloud.com/server/releases/${NEXTCLOUD_ZIP}"

cd /var/www/html || { echo "ERROR: Failed to change directory to /var/www/html. Aborting."; exit 1; }

echo "Downloading Nextcloud version ${NEXTCLOUD_VERSION}..."
wget -q ${NEXTCLOUD_DOWNLOAD_URL} # -q for quiet download
if [ ! -f "${NEXTCLOUD_ZIP}" ]; then
    echo "ERROR: Failed to download Nextcloud. Please check the URL (${NEXTCLOUD_DOWNLOAD_URL}) and network."
    exit 1
fi

echo "Unzipping Nextcloud..."
unzip -oq ${NEXTCLOUD_ZIP} # -o to overwrite existing files without prompting, -q for quiet
rm ${NEXTCLOUD_ZIP} # Clean up the zip file
mv nextcloud "${NEXTCLOUD_VERSION}" # Rename to versioned folder first
# Create/update a symlink 'nextcloud' pointing to the actual versioned folder.
# -s: symbolic, -f: force (overwrite if exists), -n: no-dereference (treat symlink target as regular file)
ln -sfn "${NEXTCLOUD_VERSION}" nextcloud 
echo "Nextcloud unzipped to ${NEXTCLOUD_VERSION} and symlinked as 'nextcloud'."

chown -R root:root "${NEXTCLOUD_VERSION}" # Set initial ownership for security before installation
cd nextcloud || { echo "ERROR: Failed to change directory to /var/www/html/nextcloud. Aborting."; exit 1; }

echo "Installing Nextcloud via occ command..."
# Ensure the data directory exists. If it's an NFS mount, it should already be handled.
# If local, ensure www-data can write to it (permissions set after install).
php occ maintenance:install --database "mysql" --database-name "nextcloud" \
    --database-user "nextcloud" --database-pass "$DBPASSWORD" \
    --admin-user "$USERNAME" --admin-pass "$PASSWORD" \
    --data-dir /mnt/files

if [ $? -ne 0 ]; then
    echo "ERROR: Nextcloud installation failed. Check logs (e.g., /mnt/files/nextcloud.log if created) or PHP/Apache logs."
    exit 1
fi
echo "Nextcloud core installed."

echo "Updating Nextcloud config.php..."
# Ensure config.php exists
if [ -f "./config/config.php" ]; then
    # Add DNSNAME as a trusted domain if not already present.
    # The grep -Fxq ensures an exact, full-line match.
    if ! php occ config:system:get trusted_domains | grep -Fxq "$DNSNAME"; then
        TRUSTED_COUNT=$(php occ config:system:get trusted_domains | wc -l)
        echo "Adding $DNSNAME as trusted domain at index $TRUSTED_COUNT."
        php occ config:system:set trusted_domains $TRUSTED_COUNT --value="$DNSNAME"
    else
        echo "$DNSNAME is already a trusted domain."
    fi

    # Update overwrite.cli.url to use HTTPS with the public DNSNAME
    php occ config:system:set overwrite.cli.url --value="https://$DNSNAME"
    echo "config.php updated: trusted_domain includes '$DNSNAME', overwrite.cli.url set to 'https://$DNSNAME'."
else
    echo "ERROR: ./config/config.php not found. Nextcloud installation might have failed or config is not where expected."
    exit 1
fi

cd .. # Back to /var/www/html

echo "Setting final permissions for Nextcloud directories..."
# Apply ownership to the actual versioned directory, not the symlink directly for clarity.
chown -R www-data:www-data "${NEXTCLOUD_VERSION}"
chown -R www-data:www-data /mnt/files # Ensure data directory is writable by web server

echo "Nextcloud installation and initial setup complete."

# --- Configure Apache ---
echo "--- Configuring Apache for Nextcloud ---"
NEXTCLOUD_APACHE_CONF="/etc/apache2/sites-available/nextcloud.conf"

# Create or overwrite the Apache config file for Nextcloud
# Using $DNSNAME for ServerName and log files.
tee "$NEXTCLOUD_APACHE_CONF" << EOF
<VirtualHost *:80>
    ServerAdmin $EMAIL
    ServerName $DNSNAME
    DocumentRoot /var/www/html/nextcloud/

    <Directory /var/www/html/nextcloud/>
        Require all granted
        Options FollowSymlinks MultiViews
        AllowOverride All

        <IfModule mod_dav.c>
            Dav off
        </IfModule>

        SetEnv HOME /var/www/html/nextcloud
        SetEnv HTTP_HOME /var/www/html/nextcloud
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$DNSNAME.error.log
    CustomLog \${APACHE_LOG_DIR}/$DNSNAME.access.log combined
</VirtualHost>
EOF
echo "Apache virtual host configuration created/updated at $NEXTCLOUD_APACHE_CONF for $DNSNAME."

# Disable default site, enable Nextcloud site, and enable required Apache modules
a2dissite 000-default.conf >/dev/null 2>&1 # Suppress output if already disabled
a2ensite nextcloud.conf
a2enmod rewrite headers env dir mime expires ssl # Added ssl here for completeness, though certbot manages it.

echo "Apache configuration updated. Restarting Apache..."
systemctl restart apache2

# --- Obtain a Certificate from Let's Encrypt ---
echo "--- Managing SSL Certificate from Let's Encrypt ---"
FINAL_URL="http://$DNSNAME (SSL not configured)" # Default access URL

if [ -z "$EMAIL" ]; then
    echo "WARNING: --email not provided. Skipping Let's Encrypt SSL certificate generation as an email is required."
elif [ "$DNSNAME" = "localhost" ] || [[ "$DNSNAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "WARNING: DNSNAME is '$DNSNAME'. Let's Encrypt cannot issue certificates for 'localhost' or IP addresses."
    echo "Skipping SSL certificate generation via Certbot."
else
    echo "Attempting to obtain SSL certificate for $DNSNAME using email $EMAIL..."
    # Ensure Apache is running and accessible from the internet on port 80 for the HTTP-01 challenge.
    certbot run --apache -d "$DNSNAME" --agree-tos -m "$EMAIL" -n --redirect --keep-until-expiring

    if [ $? -eq 0 ]; then
        echo "SSL certificate obtained/renewed and Apache configured for HTTPS successfully."
        FINAL_URL="https://$DNSNAME"
        # Certbot typically restarts Apache, but an explicit restart ensures changes are applied.
        echo "Restarting Apache to apply SSL configuration..."
        systemctl restart apache2
    else
        echo "ERROR: Certbot failed to obtain/renew SSL certificate. Check /var/log/letsencrypt/letsencrypt.log"
        echo "Ensure your domain $DNSNAME correctly resolves to this server's public IP and port 80 is open."
        echo "Nextcloud might be accessible via HTTP on http://$DNSNAME"
        FINAL_URL="http://$DNSNAME (SSL setup failed)"
    fi
fi

echo "--- Nextcloud Setup Script Finished ---"
echo "You should be able to access Nextcloud at: $FINAL_URL"
echo "Admin user: $USERNAME"
# It's good practice not to echo the admin password if it's sensitive.
# echo "Admin password: $PASSWORD (defined in script or via --password)"
echo "Please use the password you specified or the default if unchanged."
echo "Nextcloud database user 'nextcloud' password: $DBPASSWORD (store this securely if needed for manual DB access)"
