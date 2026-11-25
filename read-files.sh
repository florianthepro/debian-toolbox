find . -maxdepth 1 -type f -print0 | sort -z | while IFS= read -r -d '' f; do echo "===== ${f#./} ====="; cat -- "$f"; echo; echo "=====> end <====="; echo; done
