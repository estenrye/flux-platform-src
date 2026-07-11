<?xml version="1.0" encoding="UTF-8"?>
<!-- Injects the qemu-guest-agent virtio channel into the domain XML; the
     dmacvicar/libvirt provider has no first-class argument for channels. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>

  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="/domain/devices">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
      <channel type="unix">
        <target type="virtio" name="org.qemu.guest_agent.0"/>
      </channel>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
