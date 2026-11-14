import re

def generate_riscv_defines(raw_text):
    lines = raw_text.strip().split('\n')
    
    valid_lines = []
    buf = ""
    
    # 1. Clean up and merge lines fragmented during PDF copy-pasting
    for line in lines:
        # Remove spaces and tabs
        line = line.strip().replace(" ", "").replace("\t", "")
        if not line: 
            continue
        buf += line
        
        # Look for pattern: line should end with 7 bits (opcode) followed by letters (name)
        if re.search(r'[01]{7}[A-Za-z\.]+$', buf):
            valid_lines.append(buf)
            buf = "" # Clear buffer after successfully finding an instruction

    out = []
    out.append("// --- RISC-V AUTO-GENERATED DEFINES ---")
    
    # 2. Parse each identified instruction
    for line in valid_lines:
        # Extract the opcode (7 bits before the name) and the instruction name itself
        match = re.search(r'([01]{7})([A-Za-z\.]+)$', line)
        if not match: 
            continue
        
        opcode = match.group(1)
        name = match.group(2).upper().replace(".", "_") # Replace dots, e.g., AMOADD.W -> AMOADD_W
        
        # Determine instruction type based on specific field signatures
        itype = "UNKNOWN"
        if "imm[31:12]" in line: itype = "U"
        elif "imm[20|10:1|11|19:12]" in line: itype = "J"
        elif "imm[12|10:5]" in line: itype = "B"
        elif "imm[11:5]" in line: itype = "S"
        elif "imm[11:0]" in line or "shamt" in line: itype = "I"
        elif re.match(r'^[01]{7}', line) and "rs2" in line: itype = "R"
        
        # Look for funct3 (usually 3 bits immediately following the rs1 field)
        funct3_match = re.search(r'rs1([01]{3})', line)
        funct3 = funct3_match.group(1) if funct3_match else None
        
        # Look for funct7 (usually the first 7 bits of the string for R-type)
        funct7 = None
        if re.match(r'^[01]{7}', line):
            funct7 = line[:7]
        
        # Format the Verilog defines
        out.append(f"// {name} ({itype}-Type)")
        out.append(f"`define {itype}_{name}_opcode 7'b{opcode}")
        if funct3:
            out.append(f"`define {itype}_{name}_funct3  3'b{funct3}")
        if funct7 and itype in ['R', 'I']:
            out.append(f"`define {itype}_{name}_funct7  7'b{funct7}")
        out.append("")
        
    return "\n".join(out)

# Paste the text copied from the RISC-V PDF here
raw_pdf_text = """
imm[31:12]rd0110111LUI
imm[31:12]rd0010111AUIPC
imm[20|10:1|11|19:12]rd1101111JAL
imm[11:0]
rs1000rd1100111JALR
imm[12|10:5]rs2rs1000imm[4:1|11]1100011BEQ
imm[12|10:5]rs2rs1001imm[4:1|11]1100011BNE
imm[12|10:5]rs2rs1100imm[4:1|11]1100011BLT
imm[12|10:5]rs2rs1101imm[4:1|11]1100011BGE
imm[12|10:5]rs2rs1110imm[4:1|11]1100011BLTU
imm[12|10:5]rs2rs1111imm[4:1|11]1100011BGEU
imm[11:0]rs1000rd0000011LB
imm[11:0]rs1001rd0000011LH
imm[11:0]rs1010rd0000011LW
imm[11:0]rs1100rd0000011LBU
imm[11:0]rs1101rd0000011LHU
imm[11:5]rs2rs1000imm[4:0]0100011SB
imm[11:5]rs2rs1001imm[4:0]0100011SH
imm[11:5]rs2rs1010imm[4:0]0100011SW
imm[11:0]rs1000rd0010011ADDI
imm[11:0]rs1010rd0010011SLTI
imm[11:0]rs1011rd0010011SLTIU
imm[11:0]rs1100rd0010011XORI
imm[11:0]rs1110rd0010011ORI
imm[11:0]rs1111rd0010011ANDI
0000000shamtrs1001rd0010011SLLI
0000000shamtrs1101rd0010011SRLI
0100000shamtrs1101rd0010011SRAI
0000000rs2rs1000rd0110011ADD
0100000rs2rs1000rd0110011SUB
0000000rs2rs1001rd0110011SLL
0000000rs2rs1010rd0110011SLT
0000000rs2rs1011rd0110011SLTU
0000000rs2rs1100rd0110011XOR
0000000rs2rs1101rd0110011SRL
0100000rs2rs1101rd0110011SRA
0000000rs2rs1110rd0110011OR
0000000rs2rs1111rd0110011AND
fmpredsuccrs1000rd0001111FENCE
10000011001100000000000000001111FENCE.TSO
00000001000000000000000000001111PAUSE
00000000000000000000000001110011ECALL
00000000000100000000000001110011EBREAK

"""

print(generate_riscv_defines(raw_pdf_text))
