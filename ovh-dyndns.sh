#!/bin/bash

# DEFAULT CONFIG
declare LIBS="libs"
declare GET_IP_URL="http://ipecho.net/plain"
declare CURRENT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare API_TARGET="EU"

declare -a SUBDOMAINS
declare DOMAIN IP IDS HTTP_STATUS HTTP_RESPONSE

help()
{
    echo
    echo "Help: possible arguments are:"
    echo "  --domain <domain>             : the domain on which update the A record in the DNS zone"
    echo "  --subdomain <subdomain> ...   : (optional) the subdomain for this A record"
    echo "  --ipaddr <ipaddr>             : (optional) the IP address to use"
    echo
}

checkInternetConnexion()
{
    ping -c1 -w2 8.8.8.8 &> /dev/null
    if [ $? -ne 0 ]
    then
        exit 2
    fi
}

requestApi()
{
    local url=$1
    local method=$2
    local data=$3
    
    local -a params=("--target")
    params+=("$API_TARGET")

    params+=("--url")
    params+=("$url")
    
    if [ "$method" ]; then
        params+=("--method")
        params+=("$method")
    fi

    if [ "$data" ]; then
        params+=("--data")
        params+=("$data")
    fi
    local response=$( $CURRENT_PATH/ovh-api-bash-client.sh "${params[@]}" )
    HTTP_STATUS="$( echo $response | cut -d' ' -f1 )"
    HTTP_RESPONSE="$( echo $response | cut -d' ' -f2- )"
    echo $HTTP_STATUS
}

updateIp()
{
    [ -z "$IP" ] || return
    IP=$(wget -q -O - $GET_IP_URL)
}

getJSONString()
{
    local json="$1"
    local field="$2"
    local result=$(getJSONValue "$json" "$field")
    echo ${result:1:-1}
}

getJSONValue()
{
    local json="$1"
    local field="$2"
    local result=$(echo $json | $CURRENT_PATH/$LIBS/JSON.sh -l | grep "\[$field\]" | sed -r "s/\[$field\]\s+(.*)/\1/")
    echo ${result}
}

getJSONArrayLength()
{
    local json="$1"
    echo $json | $CURRENT_PATH/$LIBS/JSON.sh -l | wc -l
}

parseArguments()
{
    while [ $# -gt 0 ]
    do
        case $1 in
        --domain)
            shift
            DOMAIN=$1
            ;;
        --subdomain)
            shift
            SUBDOMAINS+=( $1 )
            ;;
        --ipaddr)
            shift
            IP=$1
            ;;
        esac
        shift
    done
}

checkArgumentsValids()
{
    if [ -z "$DOMAIN" ]; then
        echo "No domain given"
        help
        exit 1
    fi

    if [ -z "${#SUBDOMAINS[@]}" ]; then
        SUBDOMAINS=( "" )
    fi
}

refreshZone()
{
    requestApi "/domain/zone/$DOMAIN/refresh" 'POST' > /dev/null
}

getIds ()
{
    local subdomain="$1"
    requestApi "/domain/zone/$DOMAIN/record?subDomain=${subdomain}&fieldType=A" > /dev/null
    if [ $HTTP_STATUS -ne 200 ]; then
        echo "Error: $HTTP_STATUS $HTTP_RESPONSE"
        exit 1
    fi
    IDS="$HTTP_RESPONSE"
}

main()
{
    parseArguments "$@"
    checkArgumentsValids
    checkInternetConnexion

    updateIp

    local subdomain
    local -i needRefresh=0

    for subdomain in ${SUBDOMAINS[@]}; do
        getIds $subdomain

        if [ $(getJSONArrayLength $IDS) -gt 1 ]
        then
            echo "Error, multiple results found for record"
            echo "$IDS"
            i=0
            while [ $i -lt $(getJSONArrayLength $IDS) ]
            do
                local current_id=$(getJSONValue $IDS $i)
                requestApi "/domain/zone/$DOMAIN/record/$current_id" 'DELETE' > /dev/null
                i=$((i+1))
            done
            echo "All results were deleted, will create a new record"
            getIds $subdomain
        fi

        if [ $(getJSONArrayLength $IDS) -eq 0 ]
        then
            # No record found, create one
            requestApi "/domain/zone/$DOMAIN/record" 'POST' '{"target": "'$IP'", "subDomain": "'$subdomain'", "fieldType": "A", "ttl": 60}' > /dev/null
            refreshZone
            exit 0
        fi

        local record=$(getJSONValue $IDS '0')
        requestApi "/domain/zone/$DOMAIN/record/$record" > /dev/null
        if [ $HTTP_STATUS -ne 200 ]
        then
            echo "Error: $HTTP_STATUS $HTTP_RESPONSE"
            exit 1
        fi
        local record_ip=$(getJSONString $HTTP_RESPONSE '"target"')

        if [ $IP != $record_ip ]
        then
            requestApi "/domain/zone/$DOMAIN/record/$record" 'PUT' '{"target":"'$IP'", "ttl": 60}' > /dev/null
            needRefresh=1
        fi

    done

    if [ $needRefresh -eq 1 ]; then
        refreshZone
    fi
}

main "$@"
