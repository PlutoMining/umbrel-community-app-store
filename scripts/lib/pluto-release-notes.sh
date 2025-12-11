#!/usr/bin/env bash
# Release notes management for Pluto update scripts

# Prompt user to edit release notes interactively
prompt_release_notes() {
  local default_notes="$1"
  local final_notes=""

  if $NO_PROMPT || $DRY_RUN; then
    echo "$default_notes"
    return 0
  fi

  # Check if we're in a non-interactive environment (CI)
  if [[ -n "${CI:-}" ]] || [[ ! -t 0 ]]; then
    echo "$default_notes"
    return 0
  fi

  echo ""
  log "Release notes for this update:"
  echo "----------------------------------------"
  echo "$default_notes"
  echo "----------------------------------------"
  echo ""
  
  while true; do
    read -p "Edit release notes? (y/n) [default: n]: " -r response
    response="${response:-n}"
    
    case "$response" in
      [Yy]|[Yy][Ee][Ss])
        # Use editor if available, otherwise use read for multi-line input
        local editor="${EDITOR:-}"
        if [[ -z "$editor" ]]; then
          # Try common editors
          for e in nano vi vim; do
            if command -v "$e" >/dev/null 2>&1; then
              editor="$e"
              break
            fi
          done
        fi

        if [[ -n "$editor" ]]; then
          local tmp_file
          tmp_file=$(mktemp)
          echo "$default_notes" > "$tmp_file"
          
          if $editor "$tmp_file" 2>/dev/null; then
            final_notes=$(cat "$tmp_file")
            rm -f "$tmp_file"
            break
          else
            log "Editor failed, using default notes"
            final_notes="$default_notes"
            break
          fi
        else
          # Fallback to simple input
          log "No editor available. Enter new release notes (end with empty line + Ctrl+D or 'END' on its own line):"
          final_notes=""
          while IFS= read -r line; do
            if [[ "$line" == "END" ]]; then
              break
            fi
            if [[ -z "$final_notes" ]]; then
              final_notes="$line"
            else
              final_notes="${final_notes}"$'\n'"${line}"
            fi
          done
          if [[ -z "$final_notes" ]]; then
            final_notes="$default_notes"
          fi
          break
        fi
        ;;
      [Nn]|[Nn][Oo]|"")
        final_notes="$default_notes"
        break
        ;;
      *)
        echo "Please enter 'y' or 'n'"
        ;;
    esac
  done

  echo "$final_notes"
}

# Update release notes in umbrel-app.yml
update_release_notes() {
  local manifest="$1"
  local notes="$2"
  
  # Create temporary file with formatted notes
  local tmp_notes
  tmp_notes=$(mktemp)
  
  # Format notes: each line should be indented with 2 spaces
  # Handle empty notes
  if [[ -z "$notes" ]]; then
    echo "  " > "$tmp_notes"
  else
    echo "$notes" | while IFS= read -r line || [[ -n "$line" ]]; do
      echo "  $line" >> "$tmp_notes"
    done
  fi
  
  # Use awk to replace the releaseNotes section
  # The format is: releaseNotes: > followed by indented content
  local tmp_manifest
  tmp_manifest=$(mktemp)
  
  awk -v notes_file="$tmp_notes" '
    BEGIN {
      in_release_notes = 0
    }
    /^releaseNotes:/ {
      print "releaseNotes: >"
      in_release_notes = 1
      # Write the release notes from file
      while ((getline line < notes_file) > 0) {
        print line
      }
      close(notes_file)
      next
    }
    in_release_notes {
      # Skip old content until we hit a top-level key (starts at beginning of line, no leading space)
      # or end of file
      if (/^[a-zA-Z]/) {
        in_release_notes = 0
        print
      } else {
        # Still in release notes content (indented or blank), skip old content
        next
      }
      next
    }
    {
      print
    }
  ' "$manifest" > "$tmp_manifest"
  
  mv "$tmp_manifest" "$manifest"
  rm -f "$tmp_notes"
}
