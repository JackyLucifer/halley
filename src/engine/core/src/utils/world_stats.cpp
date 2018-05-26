#include "utils/world_stats.h"
#include "halley/core/graphics/render_context.h"
#include "graphics/text/font.h"
#include "resources/resources.h"
#include "halley/core/api/core_api.h"
#include <halley/entity/world.h>
#include <halley/entity/system.h>
#include "halley/text/string_converter.h"

using namespace Halley;

WorldStatsView::WorldStatsView(CoreAPI& coreAPI)
	: coreAPI(coreAPI)
	, text(coreAPI.getResources().get<Font>("Ubuntu Bold"), "", 16, Colour(1, 1, 1), 1.0f, Colour(0.1f, 0.1f, 0.1f))
{
}

void WorldStatsView::draw(RenderContext& context)
{
	context.bind([&] (Painter& painter) {
		int64_t grandTotal = 0;

		TimeLine timelines[] = { TimeLine::FixedUpdate, TimeLine::VariableUpdate, TimeLine::Render };
		String timelineLabels[] = { "Fixed", "Variable", "Render" };
		int i = 0;
		float width = (float(context.getCamera().getActiveViewPort().getWidth()) - 40.0f) / 3.0f;

		auto drawStats = [&] (String name, int nEntities, int64_t time, Vector2f& basePos)
		{
			text.setText(name).setAlignment(0).setPosition(basePos + Vector2f(10, 0)).draw(painter);
			text.setAlignment(1);
			if (nEntities > 0) {
				text.setText(toString(nEntities)).setPosition(basePos + Vector2f(width - 120, 0)).draw(painter);
			}
			text.setText(formatTime(time)).setPosition(basePos + Vector2f(width - 50, 0)).draw(painter);
			text.setAlignment(0);
			basePos.y += 20;
		};

		for (auto timeline : timelines) {
			int64_t total = coreAPI.getTime(CoreAPITimer::Engine, timeline, StopwatchAveraging::Mode::Average);
			int64_t gameTotal = coreAPI.getTime(CoreAPITimer::Game, timeline, StopwatchAveraging::Mode::Average);
			grandTotal += total;

			Vector2f pos = Vector2f(20 + (i++) * width, 60);
			text.setColour(Colour(0.2f, 1.0f, 0.3f)).setText(String(timelineLabels[int(timeline)]) + ": ").setPosition(pos).draw(painter);
			text.setColour(Colour(1, 1, 1));
			pos.y += 20;

			int64_t worldTotal = world ? world->getAverageTime(timeline) : 0;
			int64_t sysTotal = 0;

			if (world) {
				for (auto& system : world->getSystems(timeline)) {
					String name = system->getName();
					int64_t ns = system->getNanoSecondsTakenAvg();
					sysTotal += ns;

					drawStats(name, int(system->getEntityCount()), ns, pos);
				}

				text.setColour(Colour(0.8f, 0.8f, 0.8f));
				drawStats("[World]", 0, worldTotal - sysTotal, pos);
			}

			drawStats("[Game]", 0, gameTotal - worldTotal, pos);

			int64_t vsyncTime = 0;
			if (timeline == TimeLine::Render) {
				vsyncTime = coreAPI.getTime(CoreAPITimer::Vsync, TimeLine::Render, StopwatchAveraging::Mode::Average);
				drawStats("[VSync]", 0, vsyncTime, pos);
			}

			drawStats("[Engine]", 0, total - gameTotal - vsyncTime, pos);
			text.setColour(Colour(0.8f, 1.0f, 0.8f));
			drawStats("Total", world ? int(world->numEntities()) : 0, total, pos);
		}

		int maxFPS = int(lround(1'000'000'000.0 / grandTotal));
		text
			.setColour(Colour(1, 1, 1))
			.setText("Total elapsed: " + formatTime(grandTotal) + " ms [" + toString(maxFPS) + " FPS maximum].\n" + toString(painter.getPrevDrawCalls()) + " draw calls, " + toString(painter.getPrevTriangles()) + " triangles, " + toString(painter.getPrevVertices()) + " vertices.")
			.setPosition(Vector2f(20, 20))
			.draw(painter);
	});
}

void WorldStatsView::setWorld(const World* w)
{
	world = w;
}

String WorldStatsView::formatTime(int64_t ns) const
{
	int64_t us = (ns + 500) / 1000;
	std::stringstream ss;
	ss << (us / 1000) << '.' << std::setw(3) << std::setfill('0') << (us % 1000);
	return ss.str();
}
