// Floor that shows only the shadows falling on it: the background colour,
// darkened where a light is blocked.
float lit = 0.0;
float lights = 0.0;

void MAIN()
{
    BASE_COLOR = vec4(1.0);
}

void AMBIENT_LIGHT()
{
}

void DIRECTIONAL_LIGHT()
{
    lit += SHADOW_CONTRIB;
    lights += 1.0;
}

void SPECULAR_LIGHT()
{
}

void POST_PROCESS()
{
    float shadow = lights > 0.0 ? lit / lights : 1.0;
    COLOR_SUM = vec4(floorColor.rgb * mix(1.0 - strength, 1.0, shadow), 1.0);
}
