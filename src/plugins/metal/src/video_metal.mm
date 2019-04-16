﻿#include "video_metal.h"
#include <halley/core/graphics/texture.h>
#include <halley/core/graphics/shader.h>
#include <halley/core/graphics/material/material_definition.h>
#include <SDL2/SDL.h>

using namespace Halley;

///////////////
// Constructor
VideoMetal::VideoMetal(SystemAPI& system)
  : system(system)
{
}

void VideoMetal::init()
{
}

void VideoMetal::deInit()
{
  std::cout << "Shutting down Metal..." << std::endl;
}

void VideoMetal::startRender()
{
  surface = [swap_chain nextDrawable];
}

void VideoMetal::finishRender()
{
  window->swap();
  [surface release];
}


void VideoMetal::setWindow(WindowDefinition&& windowDescriptor)
{
  window = system.createWindow(windowDescriptor);
  initSwapChain(*window);
}

void VideoMetal::initSwapChain(Window& window) {
  if (window.getNativeHandleType() != "SDL") {
    throw Exception("Only SDL2 windows are supported by Metal", HalleyExceptions::VideoPlugin);
  }
  SDL_Window* sdl_window = static_cast<SDL_Window*>(window.getNativeHandle());
  SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
  SDL_Renderer *renderer = SDL_CreateRenderer(sdl_window, -1, SDL_RENDERER_PRESENTVSYNC);
  swap_chain = static_cast<CAMetalLayer*>(SDL_RenderGetMetalLayer(renderer));
  SDL_DestroyRenderer(renderer);
  swap_chain.pixelFormat = MTLPixelFormatBGRA8Unorm;
  device = swap_chain.device;
  command_queue = [device newCommandQueue];
  std::cout << "\tGot Metal device: " << [device.name UTF8String] << std::endl;
}

const Window& VideoMetal::getWindow() const
{
  return *window;
}

bool VideoMetal::hasWindow() const
{
  return window != nullptr;
}


std::unique_ptr<Texture> VideoMetal::createTexture(Vector2i size)
{
  return std::make_unique<MetalTexture>(size);
}

std::unique_ptr<Shader> VideoMetal::createShader(const ShaderDefinition& definition)
{
  std::cout << "Creating shader for definition: " << definition.name << std::endl;
  std::cout << "Got " << definition.vertexAttributes.size() << " vertex attributes." << std::endl;
  for (auto const& attr : definition.vertexAttributes) {
    std::cout << "\tGot vertex attribute: " << attr.name << std::endl;
  }
  if (definition.shaders.find(ShaderType::Combined) == definition.shaders.end()) {
    throw Exception("Metal requires combined shaders", HalleyExceptions::VideoPlugin);
  }
  auto shader = definition.shaders.at(ShaderType::Combined);
  auto shaderSrc = std::string(shader.begin(), shader.end());
  auto compileOptions = [MTLCompileOptions new];
  NSError* compileError;
  id<MTLLibrary> lib = [device newLibraryWithSource:[NSString stringWithUTF8String:shaderSrc.c_str()]
      options:compileOptions error:&compileError
  ];
  if (compileError) {
    std::cout << "Metal shader compilation failed for material " << definition.name << std::endl;
    throw Exception([[compileError localizedDescription] UTF8String], HalleyExceptions::VideoPlugin);
  }
  auto fragment_func = [lib newFunctionWithName:@"pixel_func"];
  if (fragment_func == nil) {
    throw Exception("Shader for " + definition.name + " is missing a fragment function.", HalleyExceptions::VideoPlugin);
  }
  auto vertex_func = [lib newFunctionWithName:@"vertex_func"];
  if (vertex_func == nil) {
    throw Exception("Shader for " + definition.name + " is missing a vertex function.", HalleyExceptions::VideoPlugin);
  }
  [lib release];
  [compileOptions release];
  [compileError release];
  return std::make_unique<MetalShader>(vertex_func, fragment_func);
}

std::unique_ptr<TextureRenderTarget> VideoMetal::createTextureRenderTarget()
{
  return std::make_unique<TextureRenderTarget>();
}

std::unique_ptr<ScreenRenderTarget> VideoMetal::createScreenRenderTarget()
{
  return std::make_unique<ScreenRenderTarget>(Rect4i({}, getWindow().getWindowRect().getSize()));
}

std::unique_ptr<MaterialConstantBuffer> VideoMetal::createConstantBuffer()
{
  return std::make_unique<MetalMaterialConstantBuffer>();
}

String VideoMetal::getShaderLanguage()
{
  return "metal";
}

std::unique_ptr<Painter> VideoMetal::makePainter(Resources& resources)
{
  return std::make_unique<MetalPainter>(*this, resources);
}

id<CAMetalDrawable> VideoMetal::getSurface() {
  return surface;
}

id<MTLCommandQueue> VideoMetal::getCommandQueue() {
  return command_queue;
}

id<MTLDevice> VideoMetal::getDevice() {
  return device;
}

MetalTexture::MetalTexture(Vector2i size)
  : Texture(size)
{
}

void MetalTexture::load(TextureDescriptor&&)
{
  doneLoading();
}

MetalShader::MetalShader(id<MTLFunction> vertex, id<MTLFunction> fragment)
  : vertex_func(vertex)
  , fragment_func(fragment)
{}

MetalShader::~MetalShader() {
  [vertex_func release];
  [fragment_func release];
}

int MetalShader::getUniformLocation(const String&, ShaderType)
{
  return 0;
}

int MetalShader::getBlockLocation(const String&, ShaderType)
{
  return 0;
}

id<MTLFunction> MetalShader::getVertexFunc() {
  return vertex_func;
}

id<MTLFunction> MetalShader::getFragmentFunc() {
  return fragment_func;
}

void MetalMaterialConstantBuffer::update(const MaterialDataBlock&) {}


MetalPainter::MetalPainter(VideoMetal& video, Resources& resources)
  : Painter(resources)
  , video(video)
{}

void MetalPainter::clear(Colour colour) {}

void MetalPainter::setMaterialPass(const Material& material, int passNumber) {
  auto& pass = material.getDefinition().getPass(passNumber);
  // TODO blending
  MetalShader& shader = static_cast<MetalShader&>(pass.getShader());

  MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
  pipelineStateDescriptor.vertexFunction = shader.getVertexFunc();
  pipelineStateDescriptor.fragmentFunction = shader.getFragmentFunc();
  pipelineStateDescriptor.label = [NSString stringWithUTF8String:material.getDefinition().getName().c_str()];
  pipelineStateDescriptor.colorAttachments[0].pixelFormat = video.getSurface().texture.pixelFormat;

  NSError* error = NULL;
  id<MTLRenderPipelineState> pipelineState = [video.getDevice() newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
      error:&error
  ];
  if (!pipelineState) {
    std::cout << "Failed to create pipeline descriptor for material " << material.getDefinition().getName() <<
      ", pass " << passNumber << "." << std::endl;
    throw Exception([[error localizedDescription] UTF8String], HalleyExceptions::VideoPlugin);
  }
  [encoder setRenderPipelineState:pipelineState];
}

void MetalPainter::doStartRender() {
  buffer = [video.getCommandQueue() commandBuffer];
  auto col = Colour4f(0);
  auto descriptor = renderPassDescriptorForTextureAndColour(video.getSurface().texture, col);
  encoder = [buffer renderCommandEncoderWithDescriptor:descriptor];
  [descriptor release];
}

void MetalPainter::doEndRender() {
  [encoder endEncoding];
  [buffer presentDrawable:video.getSurface()];
  [buffer commit];
  [encoder release];
  [buffer release];
  [indexBuffer release];
}

void MetalPainter::setVertices(
  const MaterialDefinition& material, size_t numVertices, void* vertexData, size_t numIndices,
  unsigned short* indices, bool standardQuadsOnly
) {
  Expects(numVertices > 0);
  Expects(numIndices >= numVertices);
  Expects(vertexData);
  Expects(indices);

  size_t bytesSize = numVertices * material.getVertexStride();
  [encoder setVertexBytes:vertexData length:bytesSize atIndex:0];

  indexBuffer = [video.getDevice() newBufferWithBytes:indices
      length:numIndices*sizeof(short) options:MTLResourceStorageModeShared
  ];
}

void MetalPainter::drawTriangles(size_t numIndices) {
  Expects(numIndices > 0);
  Expects(numIndices % 3 == 0);

  [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
    indexCount:numIndices
    indexType:MTLIndexTypeUInt16
    indexBuffer:indexBuffer
    indexBufferOffset:0
  ];
}

void MetalPainter::setViewPort(Rect4i rect) {
  [encoder setViewport:(MTLViewport){
    static_cast<double>(rect.getTopLeft().x),
    static_cast<double>(rect.getTopLeft().y),
    static_cast<double>(rect.getWidth()),
    static_cast<double>(rect.getHeight()),
    0.0, 1.0
  }];
}

void MetalPainter::setClip(Rect4i, bool) {}

void MetalPainter::setMaterialData(const Material&) {}

void MetalPainter::onUpdateProjection(Material& material) {
  material.uploadData(*this);
  setMaterialData(material);
}
