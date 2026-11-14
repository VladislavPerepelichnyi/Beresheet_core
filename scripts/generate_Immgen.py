import re

def generate_immgen_case(raw_text):
    lines = raw_text.strip().split('\n')
    
    valid_lines = []
    buf = ""
    
    # 1. Clean up and merge lines fragmented during PDF copy-pasting
    for line in lines:
        # Remove spaces and tabs
        line = line.strip().replace(" ", "").replace("\t", "")
        if not line: continue
        buf += line
        
        # Pattern: line must end with 7 binary digits (opcode) followed by instruction name
        if re.search(r'[01]{7}[A-Za-z\.]+$', buf):
            valid_lines.append(buf)
            buf = "" # Reset buffer after successful match
            
    # Dictionary to store: opcode -> {format type, list of instruction names}
    opcodes = {}
    
    # 2. Parse instructions
    for line in valid_lines:
        match = re.search(r'([01]{7})([A-Za-z\.]+)$', line)
        if not match: continue
        
        opcode = match.group(1)
        name = match.group(2).upper().replace(".", "_")
        
        # Determine the Immediate (Imm) format type
        itype = "UNKNOWN"
        if "imm[31:12]" in line: itype = "U"
        elif "imm[20|10:1|11|19:12]" in line: itype = "J"
        elif "imm[12|10:5]" in line: itype = "B"
        elif "imm[11:5]" in line: itype = "S"
        elif "imm[11:0]" in line or "shamt" in line: itype = "I"
        elif re.match(r'^[01]{7}', line) and "rs2" in line: itype = "R"
        
        # R-type instructions do not require ImmGen logic
        if itype in ["R", "UNKNOWN"]:
            continue 
            
        if opcode not in opcodes:
            opcodes[opcode] = {'type': itype, 'names': []}
        opcodes[opcode]['names'].append(name)

    # 3. Verilog code templates for each RISC-V immediate format
    # These templates perform sign extension and bit reconstruction
    rules = {
        "I": "{{20{instruction[31]}}, instruction[31:20]};",
        "S": "{{20{instruction[31]}}, instruction[31:25], instruction[11:7]};",
        "B": "{{20{instruction[31]}}, instruction[7], instruction[30:25], instruction[11:8], 1'b0};",
        "U": "{instruction[31:12], 12'b0};",
        "J": "{{12{instruction[31]}}, instruction[19:12], instruction[20], instruction[30:21], 1'b0};"
    }
    
    # 4. Generate Output
    out = ["case (instruction[6:0])"]
    
    for op, data in opcodes.items():
        itype = data['type']
        names = ", ".join(data['names'])
        logic = rules.get(itype, "32'b0;")
        
        # Format the line for readability in Verilog
        out.append(f"    7'b{op}: imm_out = {logic:<70} // {itype}-type ({names})")
        
    out.append("    default: imm_out = 32'b0;")
    out.append("endcase")
        
    return "\n".join(out)

# Input text block from the RISC-V specification
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
"""

print(generate_immgen_case(raw_pdf_text))
