shader_type canvas_item;

uniform sampler2D base_image : filter_nearest;
uniform sampler2D panoptic_ground_truth : filter_nearest;
uniform sampler2D overlay_panoptic : filter_nearest;

// Size of the Control in pixels (set from script)
uniform vec2 control_size = vec2(1920.0, 1080.0);

// Zoom / pan in texture space
uniform float zoom : hint_range(0.1, 10.0) = 1.0;
uniform vec2 pan = vec2(0.5, 0.5);

// Color for the letterbox area
uniform vec4 bar_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

// Overlay opacities
uniform float overlay_alpha : hint_range(0.0, 1.0) = 0.4;
uniform float highlight_alpha : hint_range(0.0, 1.0) = 0.85;

// Selected instance IDs (supports multi-select).
uniform int selected_count = 0;
uniform float selected_ids[64];

bool is_selected(float id) {
	for (int i = 0; i < selected_count; i++) {
		if (abs(id - selected_ids[i]) < 0.5) {
			return true;
		}
	}
	return false;
}

float decode_id(vec3 rgb) {
	// Convert 0–1 RGB to 0–255 and pack into a 24-bit integer.
	vec3 c = floor(rgb * 255.0 + 0.5);
	return c.r + c.g * 256.0 + c.b * 65536.0;
}

void fragment() {
	// Compute aspect-ratio–correct UV (same logic as in GDScript)
	ivec2 tex_size_i = textureSize(base_image, 0);
	vec2 tex_size = vec2(tex_size_i);
	float tex_aspect = tex_size.x / tex_size.y;
	float ctrl_aspect = control_size.x / control_size.y;

	vec2 rUV;
	if (tex_aspect <= ctrl_aspect) {
		// Texture is narrower -> fit height, bars LEFT/RIGHT
		float width_frac = tex_aspect / ctrl_aspect;
		float left  = 0.5 - width_frac * 0.5;

		float u_img = (UV.x - left) / width_frac;
		float v_img = UV.y;

		rUV = vec2(u_img, v_img);
	} else {
		// Texture is wider -> fit width, bars TOP/BOTTOM
		float height_frac = ctrl_aspect / tex_aspect;
		float top = 0.5 - height_frac * 0.5;

		float u_img = UV.x;
		float v_img = (UV.y - top) / height_frac;

		rUV = vec2(u_img, v_img);
	}

	vec2 tex_uv = (rUV - 0.5) / zoom + pan;

	// Outside the image -> letterbox
	if (tex_uv.x < 0.0 || tex_uv.x > 1.0 || tex_uv.y < 0.0 || tex_uv.y > 1.0) {
		discard;
	}

	vec4 base = texture(base_image, tex_uv);
	vec4 gt = texture(panoptic_ground_truth, tex_uv);

	// Assume pure black (0,0,0) is "no label"
	bool has_label = any(greaterThan(gt.rgb, vec3(0.0)));
	float id = has_label ? decode_id(gt.rgb) : -1.0;

	float a = 0.0;
	if (has_label) {
		a = overlay_alpha;
		if (is_selected(id)) {
			a = highlight_alpha;
		}
	}

	vec3 overlay_color = texture(overlay_panoptic, tex_uv).rgb;
	vec3 result_rgb = mix(base.rgb, overlay_color, a);

	COLOR = vec4(result_rgb, 1.0);
}
