use rustler::{NifTaggedEnum, NifStruct};

#[derive(NifTaggedEnum, Clone)]
enum Instruction {
    Push(f64),
    Add,
    Sub,
    Mul,
    Div,
    Load(u32),
    Store(u32),
    GetStart,
    GetEnd,
    Loop(u32, u32), // iterations, body_length
}

#[derive(NifStruct)]
#[module = "ManifoldEngine.Native.Estimation"]
struct Estimation {
    effort: f64,
    recommended_shards: u32,
}

#[rustler::nif]
fn estimate_task(program: Vec<Instruction>, start: f64, end: f64) -> Estimation {
    // Estimator: Purely functional complexity analysis before execution.
    let mut total_effort = 0.0;
    let range = (end - start).abs();

    let mut i = 0;
    while i < program.len() {
        match &program[i] {
            Instruction::Loop(iters, body_len) => {
                let mut body_effort = 0.0;
                for j in 1..=(*body_len as usize) {
                    if i + j < program.len() {
                        body_effort += instruction_cost(&program[i + j]);
                    }
                }
                total_effort += (*iters as f64) * body_effort;
                i += (*body_len as usize) + 1;
            }
            instr => {
                total_effort += instruction_cost(instr);
                i += 1;
            }
        }
    }

    if range > 0.0 { total_effort *= range; }

    let recommended_shards = if total_effort > 1000.0 {
        (total_effort / 500.0).ceil() as u32
    } else {
        1
    };

    Estimation { effort: total_effort, recommended_shards }
}

fn instruction_cost(instr: &Instruction) -> f64 {
    match instr {
        Instruction::Push(_) => 1.0,
        Instruction::Add | Instruction::Sub => 1.0,
        Instruction::Mul | Instruction::Div => 2.0,
        Instruction::Load(_) | Instruction::Store(_) => 1.5,
        Instruction::GetStart | Instruction::GetEnd => 0.5,
        Instruction::Loop(_, _) => 0.0,
    }
}

#[rustler::nif]
fn execute_task(program: Vec<Instruction>, start: f64, end: f64) -> f64 {
    // Executor: Deterministic VM with private memory/stack per task shard.
    let mut stack: Vec<f64> = Vec::new();
    let mut memory: std::collections::HashMap<u32, f64> = std::collections::HashMap::new();

    let mut pc = 0;
    while pc < program.len() {
        match &program[pc] {
            Instruction::Push(v) => stack.push(*v),
            Instruction::Add => {
                let b = stack.pop().unwrap_or(0.0);
                let a = stack.pop().unwrap_or(0.0);
                stack.push(a + b);
            }
            Instruction::Sub => {
                let b = stack.pop().unwrap_or(0.0);
                let a = stack.pop().unwrap_or(0.0);
                stack.push(a - b);
            }
            Instruction::Mul => {
                let b = stack.pop().unwrap_or(0.0);
                let a = stack.pop().unwrap_or(0.0);
                stack.push(a * b);
            }
            Instruction::Div => {
                let b = stack.pop().unwrap_or(0.0);
                let a = stack.pop().unwrap_or(0.0);
                if b != 0.0 { stack.push(a / b); } else { stack.push(0.0); }
            }
            Instruction::Load(addr) => stack.push(*memory.get(addr).unwrap_or(&0.0)),
            Instruction::Store(addr) => {
                if let Some(v) = stack.pop() { memory.insert(*addr, v); }
            }
            Instruction::GetStart => stack.push(start),
            Instruction::GetEnd => stack.push(end),
            Instruction::Loop(iters, body_len) => {
                let body_start = pc + 1;
                let body_end = pc + 1 + (*body_len as usize);
                let body = program[body_start..body_end].to_vec();
                for _ in 0..*iters {
                    let result = execute_task_internal(&body, start, end, &mut memory);
                    stack.push(result);
                }
                pc += *body_len as usize;
            }
        }
        pc += 1;
    }
    stack.pop().unwrap_or(0.0)
}

fn execute_task_internal(
    program: &[Instruction],
    start: f64,
    end: f64,
    memory: &mut std::collections::HashMap<u32, f64>,
) -> f64 {
    let mut stack: Vec<f64> = Vec::new();
    let mut pc = 0;
    while pc < program.len() {
        match &program[pc] {
            Instruction::Push(v) => stack.push(*v),
            Instruction::Add => {
                let b = stack.pop().unwrap_or(0.0);
                let a = stack.pop().unwrap_or(0.0);
                stack.push(a + b);
            }
            Instruction::Sub => {
                let b = stack.pop().unwrap_or(0.0);
                let a = stack.pop().unwrap_or(0.0);
                stack.push(a - b);
            }
            Instruction::Mul => {
                let b = stack.pop().unwrap_or(0.0);
                let a = stack.pop().unwrap_or(0.0);
                stack.push(a * b);
            }
            Instruction::Div => {
                let b = stack.pop().unwrap_or(0.0);
                let a = stack.pop().unwrap_or(0.0);
                if b != 0.0 { stack.push(a / b); } else { stack.push(0.0); }
            }
            Instruction::Load(addr) => stack.push(*memory.get(addr).unwrap_or(&0.0)),
            Instruction::Store(addr) => {
                if let Some(v) = stack.pop() { memory.insert(*addr, v); }
            }
            Instruction::GetStart => stack.push(start),
            Instruction::GetEnd => stack.push(end),
            Instruction::Loop(iters, body_len) => {
                let body_start = pc + 1;
                let body_end = pc + 1 + (*body_len as usize);
                let body = &program[body_start..body_end];
                for _ in 0..*iters {
                    let result = execute_task_internal(body, start, end, memory);
                    stack.push(result);
                }
                pc += *body_len as usize;
            }
        }
        pc += 1;
    }
    stack.pop().unwrap_or(0.0)
}

#[rustler::nif]
fn geometric_distance(
    node_features: Vec<f64>,
    task_req: Vec<f64>,
    current_load: f64,
    capacity: f64,
    trust_index: f64,
    latency: f64,
) -> f64 {
    // Manifold Metric: Minkowski L3 distance distorted by load and trust dilation.
    let dist: f64 = node_features.iter().zip(task_req.iter())
        .map(|(f, r)| (f - r).abs().powi(3)).sum::<f64>().powf(1.0 / 3.0);

    let load_ratio = if capacity > 0.0 { current_load / capacity } else { 1.0 };
    let distortion = (2.0 * load_ratio).exp();
    let trust_penalty = 1.0 / (trust_index.max(0.001));

    dist * distortion * trust_penalty * latency
}

rustler::init!(
    "Elixir.ManifoldEngine.Native"
);
