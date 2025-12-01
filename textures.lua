local ffi = require('ffi');
local d3d8 = require('d3d8');
local imgui = require('imgui');
local d3d8_device = d3d8.get_device();

local function LoadTexture(filePath)
    local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    if (ffi.C.D3DXCreateTextureFromFileA(d3d8_device, filePath, dx_texture_ptr) == ffi.C.S_OK) then
        return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0]));
    end
    return nil;
end

local textures = {};

textures.Initialize = function(self)
    if self.Cache then
        return;
    end

    self.Cache = {};
    local directory = string.format('%saddons/enemystats/icons/', AshitaCore:GetInstallPath());
    local contents = ashita.fs.get_directory(directory, '.*');
    if (contents) then
        for _, file in pairs(contents) do
            local index = string.find(file, '%.');
            if (index) then
                local key = string.sub(file, 1, index - 1);
                self.Cache[key] = LoadTexture(string.format('%saddons/enemystats/icons/%s', AshitaCore:GetInstallPath(),
                    file));
            end
        end
    end
end

-- Helper to draw an icon image
textures.DrawIcon = function(self, name, scale)
    scale = scale or 1.0;
    if (self.Cache and self.Cache[name]) then
        imgui.Image(tonumber(ffi.cast("uint32_t", self.Cache[name])),
            { 13 * scale, 13 * scale }, { 0, 0 }, { 1, 1 }, { 1, 1, 1, 1 }, { 0, 0, 0, 0 });
        return true;
    end
    return false;
end

-- Helper to draw icon on same line
textures.DrawIconSameLine = function(self, name, scale)
    imgui.SameLine(0, 2);
    return self:DrawIcon(name, scale);
end

return textures;
