#!/usr/bin/env bash

########################
#       Env var        #
########################
shouldTouchTraefik=false

if test -f ".env"; then
    source .env

    if [ "$shouldTouchTraefik" = true ] && [ -z ${traefikConfigPath+x} ]; then
        echo "traefikConfigPath is not set, please update your .env file"
    fi
else
    echo "No .env file found, please create one..."
    exit 1
fi

# Check if running in WSL env
runningInWsl=false
if grep -qEi "(Microsoft|WSL)" /proc/version &>/dev/null; then
    runningInWsl=true
fi

canRunWslSudo=false
if [ $runningInWsl = true ]; then
    version=$(python3 -V 2>&1 | grep -Po '(?<=Python 3\.)(\d+)')
    if [[ -z "$version" ]]; then
        echo "Installing python3"
        sudo apt update && sudo apt satisfy "python3 (>= 3.5)"
        version=$(python3 -V 2>&1 | grep -Po '(?<=Python 3\.)(\d+)')
    fi
    if [[ "$version" -ge "5" ]]; then
        canRunWslSudo=true
    fi
fi

########################
#   ROOT CA creation   #
########################
SUBJECT="/C=FR/ST=France/L=Lyon/O=Develop/CN=local.test"
NUM_OF_DAYS=36500

# Creating custom root ca-certificates folder
sudo mkdir -p /usr/local/share/ca-certificates/custom-local
# Cleaning existing cert
sudo rm -f /usr/local/share/ca-certificates/custom-local/local-dev.crt

# Check if a root CA already exists
if test -f "rootCA/rootCA.crt" && openssl x509 -checkend 86400 -noout -in rootCA/rootCA.crt; then
    echo "Root CA existing and valid, skipping..."
else
    echo "Not Root CA found or invalid, creating one..."
    rm -rf ./rootCA
    mkdir -p ./rootCA
    openssl genrsa -out rootCA/rootCA.key 2048
    openssl req -x509 -new -nodes -key rootCA/rootCA.key -sha256 -subj "$SUBJECT" -days $NUM_OF_DAYS -out rootCA/rootCA.crt

    echo "Root CA created, installing system wide..."
    sudo cp rootCA/rootCA.crt /usr/local/share/ca-certificates/custom-local/local-dev.crt
    sudo update-ca-certificates

    echo "Installing certificate to Mozilla / Chromium products"
    certificateFile="rootCA/rootCA.crt"
    certificateName="Local Develop Cert"
    find ~/ -name "cert9.db" -exec certutil -A -n "${certificateName}" -t "TCu,Cuw,Tuw" -i ${certificateFile} -d sql:"$(dirname {})" \;
fi

if [ $runningInWsl == true ]; then
    echo "====================================================================================================================================="
    echo "== Script is running in WSL, make sure to add the Root CA (rootCA/rootCA.crt file) to the Windows Certificate Store at least once! =="
    echo "====================================================================================================================================="
fi

########################
# Hosts file appending #
########################
# Ask for new (sub)domain to add
echo "List of hosts to add to host file and certificate (INCLUDING subdomains, split by commas ',')"
read -rp "Press enter to just refresh the certificate : " domainList
cleanedDomainList="$(echo -e "${domainList}" | tr -d '[:space:]')"

if [ $canRunWslSudo == false ] && [ -n "$cleanedDomainList" ]; then
    echo "============================================================================================================================="
    echo "== Script is running in WSL but python >= 3.5 is missing. This script cannot add the domain(s) to your Windows hosts file! =="
    echo "============================================================================================================================="
    read -p "Do you want to continue anyway ? [Y/n] " -n 1 -r
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        exit 1
    fi
fi

hostFile=$(getent ahosts | awk '{$1=""}1' | awk '{print}' ORS=' ' | tr " " "\n" | sed '/^[[:space:]]*$/d')
while IFS=',' read -ra ADDR; do
    for i in "${ADDR[@]}"; do
        if ! grep -q "^$i$" <<<"$hostFile"; then
            echo -ne "Adding : "
            echo -e "\n127.0.0.1 $i" | sudo tee -a /etc/hosts
            if [ $runningInWsl == true ] && [ $canRunWslSudo == true ]; then
                echo -ne "127.0.0.1 $i to Windows Hosts file"
                python3 ../wsl-sudo/wsl-sudo.py sh -c "echo '127.0.0.1 $i' >> /mnt/c/Windows/System32/Drivers/etc/hosts"
            fi
        fi
    done
done <<<"$cleanedDomainList"

########################
# Certificate creation #
########################
echo
mkdir -p certs
cat >certs/v3.ext <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
EOF

echo "Generating certificate for domain(s):"

COUNT=0
for string in $(getent ahosts | awk '{$1=""}1' | awk '{print}' ORS=' ' | grep -Po "(?<=\s)((?:[\w-]+\.[\w-]+)+)(?=\s)" | sort | uniq); do
    for line in $string; do
        COUNT=$((COUNT + 1))
        printf "DNS.%s = %s \n" "$COUNT" "$line" >>certs/v3.ext
        COUNT=$((COUNT + 1))
        printf "DNS.%s = *.%s \n" "$COUNT" "$line" >>certs/v3.ext

        echo "$line"
        echo "*.$line"
    done
done

openssl req -new -newkey rsa:2048 -sha256 -nodes -keyout certs/localcert.key -subj "$SUBJECT" -out certs/localcert.csr
openssl x509 -req -in certs/localcert.csr -CA rootCA/rootCA.crt -CAkey rootCA/rootCA.key -CAcreateserial -out certs/localcert.crt -days $NUM_OF_DAYS -sha256 -extfile certs/v3.ext

rm certs/localcert.csr
rm certs/v3.ext

########################
#  Traefik cert update #
########################
echo
if [ "$shouldTouchTraefik" == true ]; then
    echo "Touching traefik dynamic config file to trigger a soft reload..."
    touch "$traefikConfigPath"
fi

echo
echo "DONE!"
