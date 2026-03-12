# Logging utilities for VirtFusion Provisioners

# Global log file path (will be set by init_logging)
LOG_FILE=""

log_info() {
    local msg="[INFO] $1"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="[WARN] $1"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[ERROR] $1"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

log_success() {
    local msg="[SUCCESS] $1"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

# Initialize logging to a file for real-time tracking (Rule 8 & User Request)
init_logging() {
    local app_name=$1
    LOG_FILE="/var/log/strt_inst_${app_name}.log"
    
    # Create the log file and set permissions
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    log_info "Logging inicializado em $LOG_FILE"
}
