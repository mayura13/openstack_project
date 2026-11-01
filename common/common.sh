#!/usr/bin/env bash

# OpenInfra Lab Kit - Common Functions

print_header() {
    local title="$1"

    echo
    echo "========================================"
    echo " $title"
    echo "========================================"
}

print_pass() {
    local message="$1"
    echo "[O] $message"
}

print_fail() {
    local message="$1"
    echo "[X] $message"
}

print_info() {
    local message="$1"
    echo "[INFO] $message"
}

print_error_detail() {
    local stage="$1"
    local item="$2"
    local cause="$3"
    local log_path="$4"

    echo
    echo "----------------------------------------"
    echo "[ERROR]"
    echo "Stage          : $stage"
    echo "Item           : $item"
    echo "Possible cause : $cause"
    echo "Log            : $log_path"
    echo "----------------------------------------"
}