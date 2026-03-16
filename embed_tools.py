import os

def embed_file(name, path, out):
    with open(path, "rb") as f:
        data = f.read()
    
    out.write(f"const unsigned char {name}_bytes[] = {{\n")
    for i, byte in enumerate(data):
        out.write(f"0x{byte:02x}, ")
        if (i + 1) % 12 == 0:
            out.write("\n")
    out.write("\n};\n")
    out.write(f"const unsigned int {name}_len = {len(data)};\n\n")

with open("ECMAIN/System/ECEmbeddedTools.h", "w") as f:
    f.write("#ifndef ECEmbeddedTools_h\n#define ECEmbeddedTools_h\n\n")
    embed_file("embedded_ldid", "installer/ldid", f)
    embed_file("embedded_p12", "installer/victim.p12", f)
    f.write("#endif /* ECEmbeddedTools_h */\n")
