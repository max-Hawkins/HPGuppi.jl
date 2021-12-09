# TODO: Fix underscore markdown errors
"""
Module for interacting with Hashpipe's hpguppi plugin.

See also:
['struct hpguppi_block_t'](@ref),
['struct hpguppi_databuf_t'](@ref),

['hpguppi_get_hdr_block(input_block::hpguppi_block_t)'](@ref),
['hpguppi_wrap_block(input_block::hpguppi_block_t, block_data::AbstractArray)::nothing'](@ref),

In development (not usable):
['find_first_full_block(db::hpguppi_databuf_t)::Int'](@ref),
"""
module HPGuppi

export hpguppi_databuf_t, hpguppi_block_t, hpguppi_get_block, hpguppi_get_hdr_block, N_INPUT_BLOCKS

using Hashpipe: databuf_t, HashpipeDatabuf
using Blio.GuppiRaw

# HPGUPPI_DATABUF.h constants
const ALIGNMENT_SIZE = 4096
const N_INPUT_BLOCKS = 24
const BLOCK_HDR_SIZE = 5*80*512
const BLOCK_DATA_SIZE = 128*1024*1024
const PADDING_SIZE = ALIGNMENT_SIZE - (sizeof(databuf_t) % ALIGNMENT_SIZE)
const BLOCK_SIZE = BLOCK_HDR_SIZE + BLOCK_DATA_SIZE

"""
    hpguppi_block_t

Used to hold the pointers to individual GuppiRaw
header and data.
"""
struct hpguppi_block_t
    p_hdr::Ptr{UInt8}
    p_data::Ptr{Any}
end

"""
    hpguppi_databuf_t
"""
struct hpguppi_databuf_t <: HashpipeDatabuf
    p_hp_db::Ptr{databuf_t}
    blocks::Array{hpguppi_block_t}

    function hpguppi_databuf_t(p_hp_db::Ptr{databuf_t})
        blocks_array = Array{hpguppi_block_t}(undef, N_INPUT_BLOCKS)
        p_blocks = p_hp_db + sizeof(databuf_t) + PADDING_SIZE
        for i = 0:N_INPUT_BLOCKS - 1
            p_header = p_blocks + i * BLOCK_SIZE
            p_data = p_header + BLOCK_HDR_SIZE
            blocks_array[i+1] = hpguppi_block_t(p_header, p_data)
        end
        new(p_hp_db, blocks_array)
    end
end

"""
    hpguppi_get_hdr_block(input_block::hpguppi_block_t)

Parse a GUPPI header, create a Blio.GuppiRaw header dictionary, and from the header's
internal data fields, create an array of the block's data. Runtime on the order of ~300 us.
"""
function hpguppi_get_hdr_block(input_block::hpguppi_block_t)
    grh = GuppiRaw.Header()
    buf = reshape(unsafe_wrap(Array, input_block.p_hdr, BLOCK_HDR_SIZE), (GuppiRaw.HEADER_REC_SIZE, :))
    endidx = findfirst(c->buf[1:4,c] == GuppiRaw.END, 1:size(buf,2))

    for i in 1:endidx-1
        rec = String(buf[:,i])
        k, v = split(rec, '=', limit=2)
        k = Symbol(lowercase(strip(k)))
        v = strip(v)
        if v[1] == '\''
            v = strip(v, [' ', '\''])
        elseif !isnothing(match(r"^[+-]?[0-9]+$", v))
            v = parse(Int, v)
        elseif !isnothing(tryparse(Float64, v))
            v = parse(Float64, v)
        end
        grh[k] = v
    end
    # TODO: Make custom function in GuppiRaw.jl to do this parsing from a pointer. Figure out ideal array resizing for CUDA
    model_array = Array(grh)
    dims = size(model_array)
    data = unsafe_wrap(Array{eltype(model_array)}, Ptr{eltype(model_array)}(input_block.p_data), dims)
    return grh, data
end

"""
    hpguppi_get_hdr_block(input_block::hpguppi_block_t)

Parse a GUPPI header, create a Blio.GuppiRaw header dictionary, and from the header's
internal data fields, create an array of the block's data. Runtime on the order of ~300 us.
"""
function hpguppi_get_hdr(input_block)
    grh = GuppiRaw.Header()
    buf = reshape(unsafe_wrap(Array, input_block.p_hdr, BLOCK_HDR_SIZE), (GuppiRaw.HEADER_REC_SIZE, :))
    endidx = findfirst(c->buf[1:4,c] == GuppiRaw.END, 1:size(buf,2))

    for i in 1:endidx-1
        rec = String(buf[:,i])
        k, v = split(rec, '=', limit=2)
        k = Symbol(lowercase(strip(k)))
        v = strip(v)
        if v[1] == '\''
            v = strip(v, [' ', '\''])
        elseif !isnothing(match(r"^[+-]?[0-9]+$", v))
            v = parse(Int, v)
        elseif !isnothing(tryparse(Float64, v))
            v = parse(Float64, v)
        end
        grh[k] = v
    end
    return grh
end

"""
    hpguppi_wrap_block(input_block::hpguppi_block_t, model_array::AbstractArray)

A slightly faster function to grab a GUPPI block of data. Runtime of ~100ns.
"""
function hpguppi_wrap_block(input_block::hpguppi_block_t, block_data::AbstractArray)::nothing
    block_data = unsafe_wrap(Array{eltype(block_data)}, Ptr{eltype(block_data)}(input_block.p_data), size(block_data))
end

#----------------#
# In development #
#----------------#

"""
    find_first_full_block(db::hpguppi_databuf_t)::Int

Return the index of the first full block in hpguppi databuf. Return 0 if none ready.

NOTE: 1-indexed and in development
"""
function find_first_full_block(db::hpguppi_databuf_t)::Int
    lock_mask = Hashpipe.databuf_total_mask(db.p_hpguppi_db)
    # If no blocks ready, start at 1 (1-indexed blocks array)
    if lock_mask == 0
        return 1
    end
    # TODO: Create function to find first filled block to start processing at
    # bitstring(lock_mask)
    return index
end

end # Module HPGuppi

function pin_databuf_mem(db, bytes=-1)
    if(bytes==-1) # If bytes not specified, use databuf block size (may be incorrect)
        @warn "Databuf memory size to pin not set. Setting to databuf block size: $(db.block_size)"
        bytes = db.block_size
    end

    hp_databuf = unsafe_wrap(Array{Main.Hashpipe.databuf_t}, db.p_hpguppi_db, (1))[1];
    println("Pinning $bytes of Memory:")
    for i in 1:hp_databuf.n_block
        # Get correct buffer size from databuf!
        CUDA.Mem.register(CUDA.Mem.HostBuffer,db.blocks[i].p_data , bytes)
    end
end
