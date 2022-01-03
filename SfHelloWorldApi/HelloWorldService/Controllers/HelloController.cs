using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace HelloWorldService.Controllers
{
    [ApiController]
    [Route("[controller]")]
    public class HelloController : ControllerBase
    {
        private readonly ILogger<HelloController> _logger;

        public HelloController(ILogger<HelloController> logger)
        {
            _logger = logger;
        }

        [HttpGet]
        public IEnumerable<DummyObject> Get()
        {
            var rng = new Random();
            return Enumerable.Range(1, 5).Select(index => new DummyObject
            {
                Name = Faker.Name.FullName()
            })
            .ToArray();
        }
    }
}
