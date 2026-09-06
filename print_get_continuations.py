with open('continuations.py', 'r', encoding='utf-8') as f:
    lines = f.readlines()

in_func = False
for i, line in enumerate(lines):
    if line.startswith('def get_continuations('):
        in_func = True
    if in_func:
        print(line, end='')
        if line.startswith('def get_continuations_2025'):
            break
