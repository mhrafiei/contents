import os 
import shutil
import glob 

path = 'JHU/535.742/codes_2026'

files = glob.glob(os.path.join(path, '*.ipynb'))

for file in files:
    filename = os.path.basename(file)
    new_filename = '_'.join(filename.split('_')[1:-1]) + '.ipynb'
    new_file_path = os.path.join(path, new_filename)
    
    shutil.move(file, new_file_path)
    print(f'Renamed: {filename} -> {new_filename}')