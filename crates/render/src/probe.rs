//! A tiny GPU scene (cull compute pass, three indirect draws, readback) that proves the renderer's path works on an adapter.

use crate::cull::{Camera, Instance};
use bytemuck::cast_slice;
use wgpu::util::DeviceExt;

const GRID: u32 = 10;
const BATCHES: u32 = 3;
const SIZE: u32 = 64;

pub struct ProbeResult {
    pub counts: Vec<u32>,
    pub lit_pixels: u32,
}

pub struct Probe;

impl Probe {
    /// 1,000 unit cubes on a grid, spread over three batches, and a camera that sees part of it.
    pub fn scene() -> (Vec<Instance>, Camera) {
        let mut records = Vec::new();
        for i in 0..GRID * GRID * GRID {
            let (x, y, z) = (i % GRID, (i / GRID) % GRID, i / (GRID * GRID));
            let mesh_id = i % BATCHES;
            records.push(Instance {
                rows: [
                    [1.0, 0.0, 0.0, 2.0 * x as f32],
                    [0.0, 1.0, 0.0, 2.0 * y as f32],
                    [0.0, 0.0, 1.0, 2.0 * z as f32],
                ],
                mesh_id,
                draw_distance: if mesh_id == 1 { 20.0 } else { 1000.0 },
                lod_range: 0.0,
                custom: 0.0,
            });
        }
        let planes = [
            [1.0, 0.0, 0.0, -3.5],
            [-1.0, 0.0, 0.0, 15.5],
            [0.0, 1.0, 0.0, 1.5],
            [0.0, -1.0, 0.0, 9.5],
            [0.0, 0.0, 1.0, 100.0],
            [0.0, 0.0, -1.0, 100.0],
        ];
        let view_proj = glam::Mat4::orthographic_rh(-2.0, 20.0, -2.0, 20.0, -50.0, 50.0);
        let camera = Camera {
            planes,
            pos_radius: [0.0, 0.0, 0.0, 1.0],
            view_proj: view_proj.to_cols_array_2d(),
            info: [records.len() as u32, BATCHES, 0, 0],
        };
        (records, camera)
    }

    pub async fn run(device: &wgpu::Device, queue: &wgpu::Queue) -> ProbeResult {
        let (records, camera) = Self::scene();
        let cap = records.len() as u32;

        let camera_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("camera"),
            contents: cast_slice(&[camera]),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let inst_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("instances"),
            contents: cast_slice(&records),
            usage: wgpu::BufferUsages::STORAGE,
        });
        let visible_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("visible"),
            size: (cap * BATCHES * 4) as u64,
            usage: wgpu::BufferUsages::STORAGE,
            mapped_at_creation: false,
        });
        let args: Vec<u32> = (0..BATCHES).flat_map(|_| [36, 0, 0, 0, 0]).collect();
        let args_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("args"),
            contents: cast_slice(&args),
            usage: wgpu::BufferUsages::STORAGE
                | wgpu::BufferUsages::INDIRECT
                | wgpu::BufferUsages::COPY_SRC,
        });
        // One uniform per batch, 256 bytes apart (WebGPU's default offset alignment).
        let mut bases = vec![0u32; (BATCHES * 64) as usize];
        for b in 0..BATCHES {
            bases[(b * 64) as usize] = b * cap;
        }
        let base_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("batch_base"),
            contents: cast_slice(&bases),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let verts: [[f32; 3]; 8] = [
            [-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5],
            [-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5],
        ];
        let indices: [u16; 36] = [
            0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6, 0, 4, 5, 0, 5, 1,
            3, 2, 6, 3, 6, 7, 0, 3, 7, 0, 7, 4, 1, 5, 6, 1, 6, 2,
        ];
        let vert_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("verts"),
            contents: cast_slice(&verts),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let index_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("indices"),
            contents: cast_slice(&indices),
            usage: wgpu::BufferUsages::INDEX,
        });

        let storage = |binding, visibility, read_only| wgpu::BindGroupLayoutEntry {
            binding,
            visibility,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Storage { read_only },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        };
        let uniform = |binding, visibility, dynamic| wgpu::BindGroupLayoutEntry {
            binding,
            visibility,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: dynamic,
                min_binding_size: None,
            },
            count: None,
        };
        let compute = wgpu::ShaderStages::COMPUTE;
        let vertex = wgpu::ShaderStages::VERTEX;

        let cull_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("cull"),
            entries: &[
                uniform(0, compute, false),
                storage(1, compute, true),
                storage(2, compute, false),
                storage(3, compute, false),
            ],
        });
        let draw_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("draw0"),
            entries: &[uniform(0, vertex, false), storage(1, vertex, true), storage(2, vertex, true)],
        });
        let batch_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("draw1"),
            entries: &[uniform(0, vertex, true)],
        });

        let cull_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &cull_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: camera_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: inst_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: visible_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: args_buf.as_entire_binding() },
            ],
        });
        let draw_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &draw_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: camera_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: inst_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: visible_buf.as_entire_binding() },
            ],
        });
        let batch_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &batch_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &base_buf,
                    offset: 0,
                    size: wgpu::BufferSize::new(4),
                }),
            }],
        });

        let cull_module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("cull"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/cull.wgsl").into()),
        });
        let draw_module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("probe"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/probe.wgsl").into()),
        });
        let cull_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[&cull_bgl],
            push_constant_ranges: &[],
        });
        let draw_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[&draw_bgl, &batch_bgl],
            push_constant_ranges: &[],
        });
        let cull_pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("cull"),
            layout: Some(&cull_layout),
            module: &cull_module,
            entry_point: Some("main"),
            compilation_options: Default::default(),
            cache: None,
        });
        let attrs = wgpu::vertex_attr_array![0 => Float32x3];
        let format = wgpu::TextureFormat::Rgba8Unorm;
        let draw_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("probe"),
            layout: Some(&draw_layout),
            vertex: wgpu::VertexState {
                module: &draw_module,
                entry_point: Some("vs"),
                compilation_options: Default::default(),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: 12,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &attrs,
                }],
            },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &draw_module,
                entry_point: Some("fs"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview: None,
            cache: None,
        });

        let target = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("target"),
            size: wgpu::Extent3d { width: SIZE, height: SIZE, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = target.create_view(&Default::default());
        let args_read = staging(device, (args.len() * 4) as u64);
        let pixels_read = staging(device, (SIZE * SIZE * 4) as u64);

        let mut enc = device.create_command_encoder(&Default::default());
        {
            let mut pass = enc.begin_compute_pass(&Default::default());
            pass.set_pipeline(&cull_pipeline);
            pass.set_bind_group(0, &cull_bg, &[]);
            pass.dispatch_workgroups(cap.div_ceil(64), 1, 1);
        }
        {
            let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            pass.set_pipeline(&draw_pipeline);
            pass.set_bind_group(0, &draw_bg, &[]);
            pass.set_vertex_buffer(0, vert_buf.slice(..));
            pass.set_index_buffer(index_buf.slice(..), wgpu::IndexFormat::Uint16);
            for b in 0..BATCHES {
                pass.set_bind_group(1, &batch_bg, &[b * 256]);
                pass.draw_indexed_indirect(&args_buf, (b * 20) as u64);
            }
        }
        enc.copy_buffer_to_buffer(&args_buf, 0, &args_read, 0, (args.len() * 4) as u64);
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &target,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &pixels_read,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(SIZE * 4),
                    rows_per_image: Some(SIZE),
                },
            },
            wgpu::Extent3d { width: SIZE, height: SIZE, depth_or_array_layers: 1 },
        );
        queue.submit([enc.finish()]);

        let args_bytes = read_back(device, &args_read).await;
        let pixel_bytes = read_back(device, &pixels_read).await;
        let args_out: &[u32] = cast_slice(&args_bytes);
        let counts = (0..BATCHES as usize).map(|b| args_out[b * 5 + 1]).collect();
        let lit_pixels = pixel_bytes.chunks(4).filter(|p| p[0] > 0).count() as u32;
        ProbeResult { counts, lit_pixels }
    }
}

fn staging(device: &wgpu::Device, size: u64) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("staging"),
        size,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    })
}

// Natively `poll` blocks until the map is done; on web it is a no-op and the await does the waiting.
async fn read_back(device: &wgpu::Device, buf: &wgpu::Buffer) -> Vec<u8> {
    let (tx, rx) = futures_channel::oneshot::channel();
    buf.slice(..).map_async(wgpu::MapMode::Read, move |r| {
        let _ = tx.send(r);
    });
    let _ = device.poll(wgpu::PollType::Wait);
    rx.await.expect("map callback dropped").expect("map failed");
    let data = buf.slice(..).get_mapped_range().to_vec();
    buf.unmap();
    data
}
