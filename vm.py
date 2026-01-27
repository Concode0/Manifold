
import time
import math

class VirtualMachine:
    def __init__(self, memory_size=1024):
        self.stack = []
        self.memory = [0] * memory_size
        self.pc = 0
        self.instructions = []
        self.running = False
        self.output = []
        self.steps = 0

    def load_program(self, program):
        """
        Load a list of instructions.
        Each instruction is a tuple/list: [OPCODE, ARG] or [OPCODE]
        """
        self.instructions = program
        self.pc = 0
        self.stack = []
        self.running = True
        self.output = []
        self.steps = 0

    def step(self):
        if not self.running:
            return False
        
        if self.pc >= len(self.instructions):
            self.running = False
            return False

        instr = self.instructions[self.pc]
        op = instr[0].upper()
        arg = instr[1] if len(instr) > 1 else None
        
        self.pc += 1
        self.steps += 1

        try:
            if op == 'PUSH':
                self.stack.append(arg)
            elif op == 'POP':
                self.stack.pop()
            elif op == 'ADD':
                b = self.stack.pop()
                a = self.stack.pop()
                self.stack.append(a + b)
            elif op == 'SUB':
                b = self.stack.pop()
                a = self.stack.pop()
                self.stack.append(a - b)
            elif op == 'MUL':
                b = self.stack.pop()
                a = self.stack.pop()
                self.stack.append(a * b)
            elif op == 'DIV':
                b = self.stack.pop()
                a = self.stack.pop()
                if b == 0: raise ValueError("Division by zero")
                self.stack.append(a / b)
            elif op == 'MOD':
                b = self.stack.pop()
                a = self.stack.pop()
                self.stack.append(a % b)
            elif op == 'STORE':
                val = self.stack.pop()
                addr = int(arg)
                self.memory[addr] = val
            elif op == 'LOAD':
                addr = int(arg)
                self.stack.append(self.memory[addr])
            elif op == 'JMP':
                self.pc = arg
            elif op == 'JZ':
                val = self.stack.pop()
                if val == 0:
                    self.pc = arg
            elif op == 'JNZ':
                val = self.stack.pop()
                if val != 0:
                    self.pc = arg
            elif op == 'PRINT':
                val = self.stack.pop()
                self.output.append(val)
            elif op == 'HALT':
                self.running = False
            elif op == 'SQRT':
                val = self.stack.pop()
                self.stack.append(math.sqrt(val))
            elif op == 'DUP':
                self.stack.append(self.stack[-1])
            elif op == 'SLEEP':
                # Arg is seconds
                time.sleep(arg)
            else:
                print(f"Unknown Opcode: {op}")
                self.running = False
        except Exception as e:
            print(f"VM Runtime Error at PC={self.pc-1} ({op}): {e}")
            self.running = False
            self.output.append(f"ERROR: {e}")

        return self.running

    def run(self, max_steps=1000000):
        while self.running and self.steps < max_steps:
            self.step()
        return self.output
