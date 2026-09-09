#!/usr/bin/env bashio
set -e

# Enable Jemalloc for better memory handling
export LD_PRELOAD="/usr/local/lib/libjemalloc.so.2"

local_repository='/data/repository'
pull_before_push="$(bashio::config 'repository.pull_before_push')"
included_files_manifest='/tmp/git-exporter-included-files'

function setup_git {
    repository=$(bashio::config 'repository.url')
    username=$(bashio::config 'repository.username')
    password=$(bashio::config 'repository.password')
    commiter_mail=$(bashio::config 'repository.email')
    branch=$(bashio::config 'repository.branch_name')
    ssl_verify=$(bashio::config 'repository.ssl_verification')

    if [[ "$password" != "ghp_*" ]] && [[ "$password" != "github_pat_*" ]]; then
        password=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${password}'))")
    fi

    if [ ! -d "$local_repository" ]; then
        bashio::log.info 'Create local repository'
        mkdir -p "$local_repository"
    fi
    cd "$local_repository"

    # Recover from a stale Git index lock left by an interrupted previous run.
    if [ -f '.git/index.lock' ]; then
        bashio::log.warning 'Removing stale Git index.lock from previous interrupted run'
        rm -f '.git/index.lock'
    fi

    if [ "${ssl_verify:-true}" == 'false' ]; then
        bashio::log.info 'Disabling SSL verification for git repositories'
        git config --global http.sslVerify false
    fi

    if [ ! -d .git ]; then
        fullurl="https://${username}:${password}@${repository##*https://}"
        if [ "$pull_before_push" == 'true' ]; then
            bashio::log.info 'Clone existing repository'
            git clone "$fullurl" "$local_repository"
            git checkout "$branch"
        else
            bashio::log.info 'Initialize new repository'
            git init "$local_repository"
            git remote add origin "$fullurl"
        fi
        git config user.name "${username}"
        git config user.email "${commiter_mail:-git.exporter@home-assistant}"
    fi

    # Reset secrets if existing
    git config --unset-all 'secrets.allowed' || true
    git config --unset-all 'secrets.patterns' || true
    git config --unset-all 'secrets.providers' || true

    if [ "$pull_before_push" == 'true' ]; then
        bashio::log.info 'Pull latest'
        git fetch
        git reset --hard "origin/$branch"
    fi

    git clean -f -d
}

function check_secrets {
    bashio::log.info 'Add secrets pattern'

    # Allow !secret lines
    git secrets --add -a '!secret'

    # Set prohibited patterns
    git secrets --add "password:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"
    git secrets --add "token:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"
    git secrets --add "client_id:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"
    git secrets --add "api_key:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"
    git secrets --add "chat_id:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"
    git secrets --add "allowed_chat_ids:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"
    git secrets --add "latitude:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"
    git secrets --add "longitude:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"
    git secrets --add "credential_secret:\\s?[\\'\\\"]?\\w+[\\'\\\"]?\\n?"

    if [ "$(bashio::config 'check.check_for_secrets')" == 'true' ]; then
        git secrets --add-provider -- sed '/^$/d;/^#.*/d;/^&/d;s/^.*://g;s/\s//g' /config/secrets.yaml
    fi

    if [ "$(bashio::config 'check.check_for_ips')" == 'true' ]; then
        git secrets --add '([0-9]{1,3}\.){3}[0-9]{1,3}'
        git secrets --add '([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})'

        # Allow dummy / general ips and mac
        git secrets --add -a --literal 'AA:BB:CC:DD:EE:FF'
        git secrets --add -a --literal '123.456.789.123'
        git secrets --add -a --literal '0.0.0.0'
    fi

    bashio::log.info 'Add secrets from secrets.yaml'
    prohibited_patterns=$(git config --get-all secrets.patterns)
    bashio::log.info "Prohibited patterns:\n${prohibited_patterns//\\n/\\\\n}"

    readarray -t <<<"$(bashio::config 'secrets' | grep -v '^$')"
    # shellcheck disable=SC2128
    if [ -n "$MAPFILE" ] && [ ${#MAPFILE[@]} -gt 0 ]; then
        bashio::log.info 'Add custom secrets'
        for secret in "${MAPFILE[@]}"; do
            git secrets --add "$secret"
        done
    fi

    readarray -t <<<"$(bashio::config 'allowed_secrets' | grep -v '^$')"
    # shellcheck disable=SC2128
    if [ -n "$MAPFILE" ] && [ ${#MAPFILE[@]} -gt 0 ]; then
        bashio::log.info 'Add custom allowed secrets'
        for allowed_secret in "${MAPFILE[@]}"; do
            git secrets --add -a "$allowed_secret"
        done
    fi

    bashio::log.info 'Checking for secrets'
    local -a scan_files=()
    mapfile -t scan_files < <(
        {
            find "$local_repository" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.disabled' \)
            if [ -f "$included_files_manifest" ]; then
                cat "$included_files_manifest"
            fi
        } | sort -u
    )

    if [ ${#scan_files[@]} -gt 0 ]; then
        git secrets --scan "${scan_files[@]}" \
        || (bashio::log.error 'Found secrets in files!!! Fix them to be able to commit! See https://www.home-assistant.io/docs/configuration/secrets/ for more information!' && exit 1)
    fi
}

function export_ha_config {
    bashio::log.info 'Get Home Assistant config'
    excludes=$(bashio::config 'exclude')
    excludes=("secrets.yaml" ".storage" ".cloud" "esphome/" ".uuid" "node-red/" "${excludes[@]}")

    # Cleanup existing esphome folder from config
    [ -d "${local_repository}/config/esphome" ] && rm -r "${local_repository}/config/esphome"
    # shellcheck disable=SC2068
    exclude_args=$(printf -- '--exclude=%s ' ${excludes[@]})
    # Keep this managed tree authoritative: removed or newly excluded files must disappear from the mirror.
    # shellcheck disable=SC2086
    rsync -archive --compress --delete --delete-excluded --checksum --prune-empty-dirs -q --include='.gitignore' $exclude_args /config "${local_repository}"
    sed 's/:.*$/: ""/g' /config/secrets.yaml > "${local_repository}/config/secrets.yaml"
    chmod 644 -R "${local_repository}/config"
}

function export_lovelace {
    bashio::log.info 'Get Lovelace config yaml'
    [ ! -d "${local_repository}/lovelace" ] && mkdir "${local_repository}/lovelace"
    rm -rf '/tmp/lovelace'
    mkdir -p '/tmp/lovelace'
    find /config/.storage -name "lovelace*" -printf '%f\n' | xargs -I % cp /config/.storage/% /tmp/lovelace/%.json
    /utils/jsonToYaml.py '/tmp/lovelace/' 'data'
    rsync -archive --compress --delete --delete-excluded --checksum --prune-empty-dirs -q --include='*.yaml' --exclude='*' /tmp/lovelace/ "${local_repository}/lovelace"
    chmod 644 -R "${local_repository}/lovelace"
}

function export_esphome {
    bashio::log.info 'Get ESPHome configs'
    rsync -archive --compress --delete --delete-excluded --checksum --prune-empty-dirs -q \
         --exclude='.esphome*' --include='*/' --include='.gitignore' --include='*.yaml' --include='*.disabled' --exclude='secrets.yaml' --exclude='*' \
        /config/esphome "${local_repository}"
    [ -f /config/esphome/secrets.yaml ] && sed 's/:.*$/: ""/g' /config/esphome/secrets.yaml > "${local_repository}/esphome/secrets.yaml"
    chmod 644 -R "${local_repository}/esphome"
}

function export_addons {
    local addon info_file
    local -a installed_addons=()

    mkdir -p "${local_repository}/addons"
    rm -rf '/tmp/addons'
    mkdir -p '/tmp/addons/'

    mapfile -t installed_addons < <(
        bashio::api.supervisor GET "/addons" false \
        | jq -r '.addons[]?.slug'
    )

    for addon in "${installed_addons[@]}"; do
        [ -z "$addon" ] && continue
        bashio::log.info "Get ${addon} config"

        info_file="/tmp/addon-${addon}.json"
        if bashio::api.supervisor GET "/addons/${addon}/info" false > "$info_file"; then
            if python3 /utils/sanitizeAddonInfo.py < "$info_file" > /tmp/tmp.json; then
                /utils/jsonToYaml.py /tmp/tmp.json
                mv /tmp/tmp.yaml "/tmp/addons/${addon}.yaml"
            else
                bashio::log.warning "Failed to sanitize ${addon} config; skipping"
            fi
        else
            bashio::log.warning "Failed to read ${addon} config; skipping"
        fi
        rm -f "$info_file" /tmp/tmp.json /tmp/tmp.yaml
    done

    bashio::log.info 'Get addon repositories'
    bashio::api.supervisor GET "/store/repositories" false \
      | jq '. | map(select(.source != null and .source != "core" and .source != "local")) | map({(.name): {source,maintainer,slug}}) | add' > /tmp/tmp.json
    /utils/jsonToYaml.py /tmp/tmp.json
    mv /tmp/tmp.yaml "/tmp/addons/repositories.yaml"

    rsync -archive --compress --delete --delete-excluded --checksum --prune-empty-dirs -q /tmp/addons/ "${local_repository}/addons"
    chmod 644 -R "${local_repository}/addons"
}

function find_node_red_dir {
    find /addon_configs -mindepth 1 -maxdepth 1 -type d -name '*_nodered' -print -quit 2>/dev/null
}

function export_node-red {
    local node_red_dir
    node_red_dir="$(find_node_red_dir)"

    if [ -z "$node_red_dir" ]; then
        bashio::log.warning 'Node-RED app config directory not found under /addon_configs'
        rm -rf "${local_repository}/node-red"
        return 0
    fi

    bashio::log.info "Get Node-RED flows from ${node_red_dir}"
    mkdir -p "${local_repository}/node-red"
    rsync -archive --compress --delete --delete-excluded --checksum --prune-empty-dirs -q \
          --exclude='flows_cred.json' --exclude='*.backup' --include='flows.json' --include='settings.js' --exclude='*' \
        "${node_red_dir}/" "${local_repository}/node-red/"
    chmod 644 -R "${local_repository}/node-red"
}

function include_path_is_blocked {
    local source="$1"

    case "$source" in
        */secrets.yaml|*/flows_cred.json|*/.storage/auth|*/.storage/auth.*|*/.storage/auth_provider.homeassistant|*/.storage/core.config_entries|*/.storage/application_credentials|*/.storage/cloud|*.pem|*.key|*/id_rsa*|*/id_ed25519*)
            return 0
            ;;
    esac

    return 1
}

function record_included_files {
    local destination="$1"

    if [ -f "$destination" ]; then
        printf '%s\n' "$destination" >> "$included_files_manifest"
    elif [ -d "$destination" ]; then
        find "$destination" -type f >> "$included_files_manifest"
    fi
}

function export_includes {
    local include_values pattern source rel destination
    local -a matches=()
    local -a hard_exclude_args=(
        '--exclude=secrets.yaml'
        '--exclude=flows_cred.json'
        '--exclude=core.config_entries'
        '--exclude=application_credentials'
        '--exclude=auth'
        '--exclude=auth.*'
        '--exclude=auth_provider.homeassistant'
        '--exclude=cloud'
        '--exclude=*.pem'
        '--exclude=*.key'
        '--exclude=id_rsa*'
        '--exclude=id_ed25519*'
    )

    : > "$included_files_manifest"

    # fj3 stored selective files under /include. Remove that legacy tree.
    rm -rf "${local_repository}/include"

    # /addon_configs is exclusively managed by selective include, so rebuild it every run.
    rm -rf "${local_repository}/addon_configs"

    include_values="$(bashio::config 'include')"
    if [ -z "$include_values" ]; then
        return 0
    fi

    bashio::log.info 'Get selectively included files'

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue

        case "$pattern" in
            /config/*|/addon_configs/*)
                ;;
            *)
                bashio::log.warning "Skip include outside allowed roots (/config, /addon_configs): ${pattern}"
                continue
                ;;
        esac

        if [[ "$pattern" == *'/../'* || "$pattern" == */.. ]]; then
            bashio::log.warning "Skip include containing parent traversal: ${pattern}"
            continue
        fi

        matches=()
        mapfile -t matches < <(compgen -G "$pattern" || true)

        if [ ${#matches[@]} -eq 0 ]; then
            bashio::log.warning "Include pattern matched nothing: ${pattern}"
            continue
        fi

        for source in "${matches[@]}"; do
            if include_path_is_blocked "$source"; then
                bashio::log.warning "Skip sensitive include: ${source}"
                continue
            fi

            if [[ "$source" == /config/* ]]; then
                rel="${source#/config/}"
                destination="${local_repository}/config/${rel}"
            else
                rel="${source#/addon_configs/}"
                destination="${local_repository}/addon_configs/${rel}"
            fi

            mkdir -p "$(dirname "$destination")"

            if [ -d "$source" ]; then
                mkdir -p "$destination"
                rsync -archive --compress --checksum --prune-empty-dirs -q \
                    "${hard_exclude_args[@]}" "$source/" "$destination/"
            else
                rsync -archive --compress --checksum -q \
                    "${hard_exclude_args[@]}" "$source" "$destination"
            fi

            record_included_files "$destination"
        done
    done <<< "$include_values"

    [ -d "${local_repository}/addon_configs" ] && find "${local_repository}/addon_configs" -mindepth 1 -type d -empty -delete

    if [ -s "$included_files_manifest" ]; then
        while IFS= read -r destination; do
            [ -f "$destination" ] && chmod 644 "$destination"
        done < "$included_files_manifest"
    fi
}

bashio::log.info 'Start git export'

setup_git

export_ha_config

if [ "$(bashio::config 'export.lovelace')" == 'true' ]; then
    export_lovelace
else
    rm -rf "${local_repository}/lovelace"
fi

if [ "$(bashio::config 'export.esphome')" == 'true' ] && [ -d '/config/esphome' ]; then
    export_esphome
else
    rm -rf "${local_repository}/esphome"
fi

if [ "$(bashio::config 'export.addons')" == 'true' ]; then
    export_addons
else
    rm -rf "${local_repository}/addons"
fi

if [ "$(bashio::config 'export.node_red')" == 'true' ]; then
    export_node-red
else
    rm -rf "${local_repository}/node-red"
fi

# Run selective includes after the normal export. Explicit includes override user exclude rules,
# while hard security blocks remain authoritative.
export_includes

if [ "$(bashio::config 'check.enabled')" == 'true' ]; then
    check_secrets
fi

if [ "$(bashio::config 'dry_run')" == 'true' ]; then
    git status
else
    bashio::log.info 'Commit changes and push to remote'
    git add .
    if git diff --cached --quiet; then
        bashio::log.info 'No changes to commit'
    else
        bashio::log.info 'Changed files staged for commit:'
        git diff --cached --name-status
        git commit -m "$(bashio::config 'repository.commit_message')"

        if [ ! "$pull_before_push" == 'true' ]; then
            git push --set-upstream origin "$branch" -f
        else
            git push origin
        fi
    fi
fi

bashio::log.info 'Exporter finished'
