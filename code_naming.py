import os 
import glob
import datetime

t = '20260104'

folder = 'JHU/535.742/codes'

files = sorted(glob.glob(os.path.join(folder, '*')))
files = [f for f in files if 'Backup' not in f]

for f in files:
    base = os.path.basename(f)
    extension = os.path.splitext(base)[1]
    new_name = '535.742_' + os.path.splitext(base)[0] + '_' + t + extension
    new_path = os.path.join(folder, new_name)
    os.rename(f, new_path)
    print(f'Renamed: {base} -> {new_name}')

