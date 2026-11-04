"""xHTTP benchmark: one server and one client joined by a dedicated 100 Gbit/s link.

The server runs xHTTP and the baselines (nginx, khttpd, hyper-fast-path); the
client runs wrk, wrk2 and latprobe. Both nodes boot Ubuntu 24.04, move to the
7.0 HWE kernel (one reboot) and install what the benchmark needs; progress is
in /local/logs/setup.log, and /local/setup-state/done appears when a node is
ready.

Instructions:
Wait until both nodes show /local/setup-state/done, then run
scripts/bootstrap.sh from your own machine (see README.md).
"""

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.emulab as emulab  # noqa: F401  (loads the link extensions)

pc = portal.Context()

pc.defineParameter("serverType", "Server hardware type",
                   portal.ParameterType.NODETYPE, "r6615",
                   longDescription="Node type for the server (xHTTP runs here). "
                   "r6615: one EPYC 9354P, 32 cores at 3.25 GHz, ConnectX-6 100G.")
pc.defineParameter("clientType", "Client hardware type",
                   portal.ParameterType.NODETYPE, "r6525",
                   longDescription="Node type for the load generator. It must be "
                   "stronger than the server: r6525 has 64 cores and a ConnectX-6 100G.")
pc.defineParameter("linkSpeed", "Link speed (Kbps)",
                   portal.ParameterType.BANDWIDTH, 100000000,
                   longDescription="100000000 = 100 Gbit/s. The speed picks the NIC "
                   "port: asking for 100 Gbit/s maps the link onto the 100G port.")
pc.defineParameter("sameSwitch", "Keep both nodes on one switch",
                   portal.ParameterType.BOOLEAN, True,
                   longDescription="No inter-switch hop between server and client. "
                   "Mapping fails if no two free nodes share a switch; untick then.")
pc.defineParameter("image", "Disk image",
                   portal.ParameterType.IMAGE,
                   "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD",
                   advanced=True)
pc.defineParameter("baselines", "Build khttpd and hyper-fast-path on the server",
                   portal.ParameterType.BOOLEAN, True, advanced=True)

params = pc.bindParameters()
request = pc.makeRequestRSpec()


def make_node(name, hw, ip, role):
    node = request.RawPC(name)
    node.hardware_type = hw
    node.disk_image = params.image
    iface = node.addInterface("if0")
    iface.addAddress(pg.IPv4Address(ip, "255.255.255.0"))
    flags = role + (" baselines" if role == "server" and params.baselines else "")
    node.addService(pg.Execute(
        shell="bash",
        command="sudo nohup bash /local/repository/setup/node-setup.sh %s "
                ">/dev/null 2>&1 &" % flags))
    return iface


iface_server = make_node("server", params.serverType, "10.10.1.1", "server")
iface_client = make_node("client", params.clientType, "10.10.1.2", "client")

link = request.Link("link0")
link.addInterface(iface_server)
link.addInterface(iface_client)
link.bandwidth = params.linkSpeed
link.setNoBandwidthShaping()      # never shape the link in software
if params.sameSwitch:
    link.setNoInterSwitchLinks()  # both nodes on the same switch

pc.printRequestRSpec(request)
