import os
import shutil
import uuid
import hashlib

def get_file_hash(filepath):
    """
    Calculates the MD5 hash of a file to uniquely identify its content.
    Reads in chunks to handle large files efficiently.
    """
    hasher = hashlib.md5()
    try:
        with open(filepath, 'rb') as f:
            # Read the file in 4KB chunks
            buf = f.read(4096)
            while len(buf) > 0:
                hasher.update(buf)
                buf = f.read(4096)
        return hasher.hexdigest()
    except Exception as e:
        print(f"Error reading file for hashing {filepath}: {e}")
        return None

def collect_unique_images(source_dir, dest_dir):
    if not os.path.exists(dest_dir):
        os.makedirs(dest_dir)

    # A set to store the unique hashes we have processed
    seen_hashes = set()
    
    copied_count = 0
    skipped_count = 0

    print("Scanning files...")

    for root, dirs, files in os.walk(source_dir):
        for file in files:
            if file.lower().endswith(".jpg"):
                source_file_path = os.path.join(root, file)
                
                # 1. Calculate the hash of the current file
                file_hash = get_file_hash(source_file_path)
                
                if file_hash is None:
                    continue # Skip if there was a read error

                # 2. Check if we have seen this image content before
                if file_hash in seen_hashes:
                    print(f"Skipping Duplicate: {file}")
                    skipped_count += 1
                    continue
                
                # 3. If unique, add hash to set and process copy
                seen_hashes.add(file_hash)
                
                new_filename = f"{uuid.uuid4()}.jpg"
                dest_file_path = os.path.join(dest_dir, new_filename)
                
                try:
                    shutil.copy2(source_file_path, dest_file_path)
                    print(f"Copied: {file} -> {new_filename}")
                    copied_count += 1
                except Exception as e:
                    print(f"Error copying {file}: {e}")

    print(f"\n--- Summary ---")
    print(f"Unique files copied: {copied_count}")
    print(f"Duplicates skipped:  {skipped_count}")

# --- Configuration ---
source_folder = r"./"
destination_folder = r"../image_repo"

if __name__ == "__main__":
    collect_unique_images(source_folder, destination_folder)
