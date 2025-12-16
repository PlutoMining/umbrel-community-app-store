#!/usr/bin/env bash
# Release notes management for Pluto update scripts

# Clean up release notes by removing unwanted lines
clean_release_notes() {
  local notes="$1"

  # Filter out unwanted lines:
  # - Comment lines (starting with #)
  # - Log message lines (containing [update-pluto-from-registry])
  # - Separator lines (lines with only dashes, hyphens, or mostly dashes)
  #   Match: lines that are 10+ dashes/hyphens (with optional spaces)
  notes=$(echo "$notes" | awk '
    {
      # Remove leading/trailing spaces for pattern matching
      trimmed = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)

      # Skip comment lines
      if (trimmed ~ /^#/) next

      # Skip log message lines
      if (trimmed ~ /\[update-pluto-from-registry\]/) next

      # Skip separator lines: lines that are mostly dashes (10+ dashes)
      # Remove all dashes and hyphens, if result is empty or only spaces, it's a separator
      temp = trimmed
      gsub(/[-]+/, "", temp)
      gsub(/[[:space:]]+/, "", temp)
      if (length(temp) == 0 && length(trimmed) >= 10) {
        next  # This is a separator line, skip it
      }

      print $0
    }
  ')

  # Remove duplicate consecutive "Version X.Y.Z" lines
  # If the same version line appears consecutively, keep only the first one
  notes=$(echo "$notes" | awk '
    {
      # Pattern to match version lines: "Version X.Y.Z" or "Version X.Y.Z-beta.N"
      if ($0 ~ /^[[:space:]]*Version[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?[[:space:]]*$/) {
        if (prev_line != $0) {
          print $0
          prev_line = $0
        }
        # Skip if it's the same as previous line
      } else {
        print $0
        prev_line = ""
      }
    }
  ')

  # Remove duplicate consecutive blank lines (reduce to single blank line)
  notes=$(echo "$notes" | awk 'prev == "" && $0 == "" {next} {prev=$0; print}')

  # Remove leading blank lines
  notes=$(echo "$notes" | sed '/./,$!d')

  # Remove trailing blank lines
  if command -v tac >/dev/null 2>&1; then
    notes=$(echo "$notes" | tac | sed '/./,$!d' | tac)
  else
    # Fallback: use awk to remove trailing blanks
    notes=$(echo "$notes" | awk '{lines[NR]=$0} END {for(i=1;i<=NR;i++) if(i==NR && lines[i]=="") break; else print lines[i]}')
  fi

  echo "$notes"
}

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
  echo "----------------------------------------" >&2
  echo "$default_notes" >&2
  echo "----------------------------------------" >&2
  echo "" >&2
  
  while true; do
    # Ensure we read from terminal if available
    if [[ -t 0 ]] && [[ -c /dev/tty ]]; then
      read -p "Edit release notes? (y/n) [default: n]: " -r response </dev/tty
    else
      read -p "Edit release notes? (y/n) [default: n]: " -r response
    fi
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
          # Write release notes with a helpful comment
          {
            echo "# Edit the release notes below. Remove this comment line and any separator lines."
            echo "# Lines starting with '#' will be removed automatically."
            echo ""
            echo "$default_notes"
          } > "$tmp_file"

          # Run editor with proper terminal access
          # Use explicit tty redirection to ensure editor can interact with user
          if [[ -t 0 ]] && [[ -c /dev/tty ]]; then
            # Terminal is available, run editor with tty access
            $editor "$tmp_file" </dev/tty >/dev/tty 2>&1
            local editor_exit=$?
          else
            # Fallback: run editor normally
            $editor "$tmp_file"
            local editor_exit=$?
          fi
          
          # Read the edited content and clean it up
          if [[ -f "$tmp_file" ]] && [[ -r "$tmp_file" ]]; then
            final_notes=$(cat "$tmp_file")
            # Clean up the notes
            final_notes=$(clean_release_notes "$final_notes")

            # If cleaning resulted in empty content, use default
            if [[ -z "${final_notes// }" ]] || [[ -z "$final_notes" ]]; then
              final_notes="$default_notes"
            fi
            rm -f "$tmp_file"
            break
          else
            log "Editor failed or file was not saved, using default notes"
            final_notes="$default_notes"
            [[ -f "$tmp_file" ]] && rm -f "$tmp_file"
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
          else
            # Clean up the notes
            final_notes=$(clean_release_notes "$final_notes")
            if [[ -z "${final_notes// }" ]] || [[ -z "$final_notes" ]]; then
              final_notes="$default_notes"
            fi
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

  # Final cleanup pass to ensure no unwanted content
  final_notes=$(clean_release_notes "$final_notes")

  # If cleaning resulted in empty content, use default
  if [[ -z "${final_notes// }" ]] || [[ -z "$final_notes" ]]; then
    final_notes="$default_notes"
  fi

  echo "$final_notes"
}

# Update release notes in umbrel-app.yml
update_release_notes() {
  local manifest="$1"
  local notes="$2"
  
  # Clean up notes one more time as a safety measure
  notes=$(clean_release_notes "$notes")

  # Create temporary file with formatted notes
  local tmp_notes
  tmp_notes=$(mktemp)
  
  # Format notes: each line should be indented with 2 spaces
  # Handle empty notes
  if [[ -z "$notes" ]] || [[ -z "${notes// }" ]]; then
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
