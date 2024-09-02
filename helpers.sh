function contains() {
    local item="$1"
    shift
    local arr=("$@")

    for element in "${arr[@]}"; do
        if [[ "$element" == "$item" ]]; then
            return 0
        fi
    done

    return 1
}